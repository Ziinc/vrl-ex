use std::mem::ManuallyDrop;
use std::ops::ControlFlow;
use std::time::{Duration, Instant};

use chrono::{DateTime, Datelike, NaiveDate, TimeDelta, Timelike, Utc};
use rustler::types::map::MapIterator;
use rustler::{
    Atom, Binary, Encoder, Env, Error, NewBinary, NifResult, NifStruct, ResourceArc, Term, TermType,
};
use vrl::compiler::runtime::{Runtime, Terminate};
use vrl::compiler::state::RuntimeState;
use vrl::compiler::{Program, TargetValue, TimeZone};
use vrl::diagnostic::Formatter;
use vrl::value::{KeyString, ObjectMap, ObjectMapIter, Secrets, Value};

mod atoms {
    rustler::atoms! { ok, error, abort, timeout, nil, __struct__, calendar_iso = "Elixir.Calendar.ISO" }
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

/// VRL recurses deeply on nested input, overflowing ~320KB dirty scheduler
/// stacks, so it runs on this larger (lazily committed) stack.
const STACK_SIZE: usize = 256 * 1024 * 1024;

/// Maximum container nesting accepted from and returned to Elixir.
const MAX_DEPTH: usize = 128;

pub struct ProgramResource(ManuallyDrop<Program>);

impl Drop for ProgramResource {
    fn drop(&mut self) {
        // SAFETY: the program is dropped exactly once, here.
        stacker::grow(STACK_SIZE, || unsafe { ManuallyDrop::drop(&mut self.0) });
    }
}

// Compiled programs are immutable, so a panic cannot leave them inconsistent.
impl std::panic::RefUnwindSafe for ProgramResource {}

#[rustler::resource_impl]
impl rustler::Resource for ProgramResource {}

#[rustler::nif(schedule = "DirtyCpu")]
fn compile(source: Binary, deny: Vec<String>) -> Result<ResourceArc<ProgramResource>, String> {
    let source = std::str::from_utf8(source.as_slice())
        .map_err(|_| "source must be valid UTF-8".to_owned())?;
    let fns = vrl::stdlib::all();
    if let Some(name) = deny
        .iter()
        .find(|d| !fns.iter().any(|f| f.identifier() == *d))
    {
        return Err(format!("unknown function in :deny_functions: {name:?}"));
    }
    let fns: Vec<_> = fns
        .into_iter()
        .filter(|f| !deny.iter().any(|d| d == f.identifier()))
        .collect();
    let program = stacker::grow(STACK_SIZE, || {
        vrl::compiler::compile(source, &fns)
            .map(|result| result.program)
            .map_err(|diagnostics| {
                Formatter::new(source, diagnostics)
                    .to_string()
                    .trim()
                    .to_owned()
            })
    })?;
    Ok(ResourceArc::new(ProgramResource(ManuallyDrop::new(
        program,
    ))))
}

enum Outcome {
    Ok(Value, Value, Value),
    Abort(String),
    Error(String),
    Timeout,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn run<'a>(
    env: Env<'a>,
    program: ResourceArc<ProgramResource>,
    event: Term<'a>,
    timeout_ms: Option<u64>,
    metadata: Term<'a>,
    strip_structs: bool,
) -> NifResult<Term<'a>> {
    let value = decode(event, strip_structs)?;
    let metadata = decode(metadata, strip_structs)?;
    if !metadata.is_object() {
        return Err(Error::Term(Box::new("metadata must be a map")));
    }
    let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
    // Called between expressions; the clock is sampled as reading it every
    // expression slows tight loops by ~70%.
    let mut checkpoints: u32 = 0;
    let mut control = move || {
        checkpoints = checkpoints.wrapping_add(1);
        match deadline {
            Some(deadline) if checkpoints.is_multiple_of(256) && Instant::now() >= deadline => {
                ControlFlow::Break(())
            }
            _ => ControlFlow::Continue(()),
        }
    };

    // Only pure Rust runs on the grown stack; ERTS calls stay on the scheduler stack.
    let outcome = stacker::grow(STACK_SIZE, move || {
        let mut target = TargetValue {
            value,
            metadata,
            secrets: Secrets::default(),
        };
        let mut runtime = Runtime::new(RuntimeState::default());
        match runtime.resolve_with_control(
            &mut target,
            &program.0,
            &TimeZone::default(),
            &mut control,
        ) {
            Ok(value)
                if too_deep(&value, 0)
                    || too_deep(&target.value, 0)
                    || too_deep(&target.metadata, 0) =>
            {
                Outcome::Error(depth_message())
            }
            Ok(value) => Outcome::Ok(value, target.value, target.metadata),
            Err(Terminate::Abort(err)) => Outcome::Abort(err.to_string()),
            Err(Terminate::Interrupted) => Outcome::Timeout,
            Err(err) => Outcome::Error(err.to_string()),
        }
    });

    Ok(match outcome {
        Outcome::Ok(value, event, metadata) => (
            atoms::ok(),
            encode(env, &value),
            encode(env, &event),
            encode(env, &metadata),
        )
            .encode(env),
        Outcome::Abort(message) => (atoms::error(), (atoms::abort(), message)).encode(env),
        Outcome::Error(message) => (atoms::error(), message).encode(env),
        Outcome::Timeout => (atoms::error(), atoms::timeout()).encode(env),
    })
}

fn depth_message() -> String {
    format!("maximum nesting depth of {MAX_DEPTH} exceeded")
}

fn too_deep(value: &Value, depth: usize) -> bool {
    match value {
        Value::Array(_) | Value::Object(_) if depth >= MAX_DEPTH => true,
        Value::Array(items) => items.iter().any(|v| too_deep(v, depth + 1)),
        Value::Object(map) => map.values().any(|v| too_deep(v, depth + 1)),
        _ => false,
    }
}

fn unsupported(term: Term) -> Error {
    Error::Term(Box::new(format!("unsupported term: {term:?}")))
}

// decode/encode use an explicit heap stack, not recursion: they call ERTS, so
// they must stay on the small scheduler stack.
#[allow(clippy::large_enum_variant)] // frames live on the heap
enum DecodeFrame<'a> {
    List {
        items: Vec<Value>,
        tail: Term<'a>,
    },
    Map {
        map: ObjectMap,
        iter: MapIterator<'a>,
        key: Option<KeyString>,
    },
}

impl<'a> DecodeFrame<'a> {
    fn accept(&mut self, value: Value) {
        match self {
            DecodeFrame::List { items, .. } => items.push(value),
            DecodeFrame::Map { map, key, .. } => {
                map.insert(key.take().expect("key precedes value"), value);
            }
        }
    }

    fn next_child(&mut self, strip_structs: bool) -> NifResult<Option<Term<'a>>> {
        match self {
            DecodeFrame::List { tail, .. } => {
                if tail.is_empty_list() {
                    return Ok(None);
                }
                let (head, rest) = tail
                    .list_get_cell()
                    .map_err(|_| Error::Term(Box::new("unsupported term: improper list")))?;
                *tail = rest;
                Ok(Some(head))
            }
            DecodeFrame::Map { iter, key, .. } => {
                for (k, v) in iter.by_ref() {
                    if strip_structs && k == atoms::__struct__().to_term(k.get_env()) {
                        continue;
                    }
                    *key = Some(decode_key(k)?);
                    return Ok(Some(v));
                }
                Ok(None)
            }
        }
    }

    fn finish(self) -> Value {
        match self {
            DecodeFrame::List { items, .. } => Value::Array(items),
            DecodeFrame::Map { map, .. } => Value::Object(map),
        }
    }
}

fn decode(root: Term, strip_structs: bool) -> NifResult<Value> {
    let mut stack: Vec<DecodeFrame> = Vec::new();
    let mut next = root;
    loop {
        let is_list = next.is_list() || next.is_empty_list();
        let mut ready = if !is_list && !next.is_map() {
            Some(decode_scalar(next)?)
        } else if stack.len() >= MAX_DEPTH {
            return Err(Error::Term(Box::new(depth_message())));
        } else if is_list {
            stack.push(DecodeFrame::List {
                items: Vec::new(),
                tail: next,
            });
            None
        } else if let Some(timestamp) = decode_datetime(next) {
            Some(timestamp?)
        } else {
            stack.push(DecodeFrame::Map {
                map: ObjectMap::new(),
                iter: MapIterator::new(next).ok_or(Error::BadArg)?,
                key: None,
            });
            None
        };

        loop {
            let Some(top) = stack.last_mut() else {
                return Ok(ready.expect("root value"));
            };
            if let Some(value) = ready.take() {
                top.accept(value);
            }
            if let Some(child) = top.next_child(strip_structs)? {
                next = child;
                break;
            }
            ready = stack.pop().map(DecodeFrame::finish);
        }
    }
}

fn decode_scalar(term: Term) -> NifResult<Value> {
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
        _ => Err(unsupported(term)),
    }
}

fn decode_datetime(term: Term) -> Option<NifResult<Value>> {
    let dt = term.decode::<ElixirDateTime>().ok()?;
    Some(
        dt.to_utc()
            .map(Value::Timestamp)
            .ok_or_else(|| unsupported(term)),
    )
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

enum EncodeFrame<'v, 'a> {
    Array {
        items: std::slice::Iter<'v, Value>,
        terms: Vec<Term<'a>>,
    },
    Object {
        entries: ObjectMapIter<'v>,
        keys: Vec<Term<'a>>,
        values: Vec<Term<'a>>,
    },
}

impl<'v, 'a> EncodeFrame<'v, 'a> {
    fn accept(&mut self, term: Term<'a>) {
        match self {
            EncodeFrame::Array { terms, .. } => terms.push(term),
            EncodeFrame::Object { values, .. } => values.push(term),
        }
    }

    fn next_child(&mut self, env: Env<'a>) -> Option<&'v Value> {
        match self {
            EncodeFrame::Array { items, .. } => items.next(),
            EncodeFrame::Object { entries, keys, .. } => {
                let (k, v) = entries.next()?;
                keys.push(encode_binary(env, k.as_str().as_bytes()));
                Some(v)
            }
        }
    }

    fn finish(self, env: Env<'a>) -> Term<'a> {
        match self {
            EncodeFrame::Array { terms, .. } => terms.encode(env),
            EncodeFrame::Object { keys, values, .. } => {
                Term::map_from_term_arrays(env, &keys, &values).expect("unique keys")
            }
        }
    }
}

fn encode<'a>(env: Env<'a>, root: &Value) -> Term<'a> {
    let mut stack: Vec<EncodeFrame> = Vec::new();
    let mut next = root;
    loop {
        let mut ready = match next {
            Value::Array(items) => {
                stack.push(EncodeFrame::Array {
                    items: items.iter(),
                    terms: Vec::with_capacity(items.len()),
                });
                None
            }
            Value::Object(map) => {
                stack.push(EncodeFrame::Object {
                    entries: map.iter(),
                    keys: Vec::with_capacity(map.len()),
                    values: Vec::with_capacity(map.len()),
                });
                None
            }
            scalar => Some(encode_scalar(env, scalar)),
        };

        loop {
            let Some(top) = stack.last_mut() else {
                return ready.expect("root term");
            };
            if let Some(term) = ready.take() {
                top.accept(term);
            }
            if let Some(child) = top.next_child(env) {
                next = child;
                break;
            }
            ready = stack.pop().map(|frame| frame.finish(env));
        }
    }
}

fn encode_scalar<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Bytes(bytes) => encode_binary(env, bytes),
        Value::String(string) => encode_binary(env, string.as_bytes()),
        Value::Regex(regex) => regex.as_str().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Float(f) => f.into_inner().encode(env),
        Value::Boolean(b) => b.encode(env),
        Value::Timestamp(ts) => ElixirDateTime::from_utc(ts).encode(env),
        Value::Null => atoms::nil().encode(env),
        Value::Object(_) | Value::Array(_) => unreachable!("containers are encoded by encode"),
    }
}

fn encode_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    binary.into()
}

rustler::init!("Elixir.VRL.Native");
