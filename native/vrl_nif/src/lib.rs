use chrono::{DateTime, Datelike, NaiveDate, TimeDelta, Timelike, Utc};
use rustler::types::map::MapIterator;
use rustler::{
    Atom, Binary, Encoder, Env, Error, ListIterator, NewBinary, NifResult, NifStruct, ResourceArc,
    Term, TermType,
};
use vrl::compiler::runtime::{Runtime, Terminate};
use vrl::compiler::state::RuntimeState;
use vrl::compiler::{Program, TargetValue, TimeZone};
use vrl::diagnostic::Formatter;
use vrl::value::{KeyString, ObjectMap, Secrets, Value};

mod atoms {
    rustler::atoms! { ok, error, abort, nil, calendar_iso = "Elixir.Calendar.ISO" }
}

#[derive(NifStruct)]
#[module = "DateTime"]
struct ElixirDateTime {
    calendar: Atom,
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    microsecond: (u32, u32),
    utc_offset: i64,
    std_offset: i64,
    time_zone: String,
    zone_abbr: String,
}

impl ElixirDateTime {
    fn to_utc(&self) -> Option<DateTime<Utc>> {
        let naive = NaiveDate::from_ymd_opt(self.year, self.month, self.day)?.and_hms_micro_opt(
            self.hour,
            self.minute,
            self.second,
            self.microsecond.0,
        )?;
        let offset = TimeDelta::try_seconds(self.utc_offset + self.std_offset)?;
        Some(naive.checked_sub_signed(offset)?.and_utc())
    }

    fn from_utc(ts: &DateTime<Utc>) -> Self {
        Self {
            calendar: atoms::calendar_iso(),
            year: ts.year(),
            month: ts.month(),
            day: ts.day(),
            hour: ts.hour(),
            minute: ts.minute(),
            second: ts.second(),
            // Leap seconds carry the extra second in the fraction.
            microsecond: (ts.timestamp_subsec_micros().min(999_999), 6),
            utc_offset: 0,
            std_offset: 0,
            time_zone: "Etc/UTC".to_owned(),
            zone_abbr: "UTC".to_owned(),
        }
    }
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
        TermType::Map => match term.decode::<ElixirDateTime>() {
            Ok(dt) => dt
                .to_utc()
                .map(Value::Timestamp)
                .ok_or_else(|| unsupported(term)),
            Err(_) => MapIterator::new(term)
                .ok_or(Error::BadArg)?
                .map(|(k, v)| Ok((decode_key(k)?, decode(v)?)))
                .collect::<NifResult<ObjectMap>>()
                .map(Value::Object),
        },
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
        Value::Timestamp(ts) => ElixirDateTime::from_utc(ts).encode(env),
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
