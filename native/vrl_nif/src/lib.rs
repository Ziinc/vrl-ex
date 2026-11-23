use rustler::types::map::MapIterator;
use rustler::{
    Binary, Encoder, Env, Error, ListIterator, NewBinary, NifResult, ResourceArc, Term, TermType,
};
use vrl::compiler::runtime::{Runtime, Terminate};
use vrl::compiler::state::RuntimeState;
use vrl::compiler::{Program, TargetValue, TimeZone};
use vrl::diagnostic::Formatter;
use vrl::value::{KeyString, ObjectMap, Secrets, Value};

mod atoms {
    rustler::atoms! { ok, error, abort, nil }
}

pub struct ProgramResource(Program);

// Compiled programs are immutable, so a panic cannot leave them inconsistent.
impl std::panic::RefUnwindSafe for ProgramResource {}

#[rustler::resource_impl]
impl rustler::Resource for ProgramResource {}

#[rustler::nif(schedule = "DirtyCpu")]
fn compile(source: &str) -> Result<ResourceArc<ProgramResource>, String> {
    let fns = vrl::stdlib::all();
    vrl::compiler::compile(source, &fns)
        .map(|result| ResourceArc::new(ProgramResource(result.program)))
        .map_err(|diagnostics| {
            Formatter::new(source, diagnostics)
                .to_string()
                .trim()
                .to_owned()
        })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn run<'a>(
    env: Env<'a>,
    program: ResourceArc<ProgramResource>,
    event: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut target = TargetValue {
        value: decode(event)?,
        metadata: Value::Object(ObjectMap::new()),
        secrets: Secrets::default(),
    };
    let mut runtime = Runtime::new(RuntimeState::default());

    Ok(
        match runtime.resolve(&mut target, &program.0, &TimeZone::default()) {
            Ok(value) => (atoms::ok(), encode(env, &value), encode(env, &target.value)).encode(env),
            Err(Terminate::Abort(err)) => {
                (atoms::error(), (atoms::abort(), err.to_string())).encode(env)
            }
            Err(err) => (atoms::error(), err.to_string()).encode(env),
        },
    )
}

fn unsupported(term: Term) -> Error {
    Error::Term(Box::new(format!("unsupported term: {term:?}")))
}

fn decode(term: Term) -> NifResult<Value> {
    match term.get_type() {
        TermType::Binary => Ok(Value::from(term.decode::<Binary>()?.as_slice())),
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Integer)
            .map_err(|_| unsupported(term)),
        TermType::Float => Ok(Value::from_f64_or_zero(term.decode()?)),
        TermType::Atom => {
            if let Ok(b) = term.decode::<bool>() {
                Ok(Value::Boolean(b))
            } else if term == atoms::nil().to_term(term.get_env()) {
                Ok(Value::Null)
            } else {
                Ok(Value::from(term.atom_to_string()?))
            }
        }
        TermType::List => term
            .decode::<ListIterator>()?
            .map(decode)
            .collect::<NifResult<Vec<_>>>()
            .map(Value::Array),
        TermType::Map => MapIterator::new(term)
            .ok_or(Error::BadArg)?
            .map(|(k, v)| Ok((decode_key(k)?, decode(v)?)))
            .collect::<NifResult<ObjectMap>>()
            .map(Value::Object),
        _ => Err(unsupported(term)),
    }
}

fn decode_key(term: Term) -> NifResult<KeyString> {
    match term.get_type() {
        TermType::Binary => Ok(term
            .decode::<String>()
            .map_err(|_| unsupported(term))?
            .into()),
        TermType::Atom => Ok(term.atom_to_string()?.into()),
        _ => Err(unsupported(term)),
    }
}

fn encode<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Bytes(bytes) => encode_binary(env, bytes),
        Value::String(string) => encode_binary(env, string.as_bytes()),
        Value::Regex(regex) => regex.as_str().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Float(f) => f.into_inner().encode(env),
        Value::Boolean(b) => b.encode(env),
        Value::Timestamp(ts) => ts.to_rfc3339().encode(env),
        Value::Object(map) => {
            let keys: Vec<_> = map.keys().map(|k| k.as_str().encode(env)).collect();
            let values: Vec<_> = map.values().map(|v| encode(env, v)).collect();
            Term::map_from_term_arrays(env, &keys, &values).expect("unique keys")
        }
        Value::Array(items) => items
            .iter()
            .map(|v| encode(env, v))
            .collect::<Vec<_>>()
            .encode(env),
        Value::Null => atoms::nil().encode(env),
    }
}

fn encode_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

rustler::init!("Elixir.VRL.Native");
