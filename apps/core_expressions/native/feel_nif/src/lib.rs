use dsntk_feel::context::FeelContext;
use dsntk_feel::values::Value;
use dsntk_feel::{FeelNumber, FeelScope, Name, value_number};
use dsntk_feel_evaluator::evaluate;
use dsntk_feel_parser::{parse_expression, AstNode};
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};
use std::collections::HashMap;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        feel_date,
        feel_time,
        feel_datetime,
        feel_duration_dt,
        feel_duration_ym,
    }
}

struct CompiledExpression {
    ast: Mutex<AstNode>,
}

#[rustler::resource_impl]
impl rustler::Resource for CompiledExpression {}

rustler::init!("Elixir.BfwEngine.Expressions.Nif");

// ---------------------------------------------------------------------------
// NIF functions
// ---------------------------------------------------------------------------

/// Parse a FEEL expression with a context that provides variable names
/// for the scope-aware parser. Returns `{:ok, resource}` | `{:error, reason}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn compile<'a>(
    env: Env<'a>,
    expression: String,
    context: Term<'a>,
) -> NifResult<Term<'a>> {
    let scope = match build_scope(env, context) {
        Ok(s) => s,
        Err(msg) => return Ok((atoms::error(), msg).encode(env)),
    };

    match parse_expression(&scope, &expression, false) {
        Ok(ast) => {
            let resource = ResourceArc::new(CompiledExpression {
                ast: Mutex::new(ast),
            });
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("{}", e)).encode(env)),
    }
}

/// Evaluate a previously compiled expression against a runtime context.
/// Returns `{:ok, value}` | `{:error, reason}`.
#[rustler::nif]
fn eval_compiled<'a>(
    env: Env<'a>,
    resource: ResourceArc<CompiledExpression>,
    context: Term<'a>,
) -> NifResult<Term<'a>> {
    let feel_ctx = match term_to_feel_context(env, context) {
        Ok(ctx) => ctx,
        Err(msg) => return Ok((atoms::error(), msg).encode(env)),
    };

    let scope = FeelScope::from(feel_ctx);
    let ast_guard = resource
        .ast
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    let result = evaluate(&scope, &ast_guard);

    Ok((atoms::ok(), feel_value_to_term(env, &result)).encode(env))
}

/// Parse and evaluate a FEEL expression in one shot. Useful for one-off
/// evaluations where precompilation overhead is not justified.
/// Returns `{:ok, value}` | `{:error, reason}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn eval_expression<'a>(
    env: Env<'a>,
    expression: String,
    context: Term<'a>,
) -> NifResult<Term<'a>> {
    let feel_ctx = match term_to_feel_context(env, context) {
        Ok(ctx) => ctx,
        Err(msg) => return Ok((atoms::error(), msg).encode(env)),
    };

    let scope = FeelScope::from(feel_ctx);
    let ast = match parse_expression(&scope, &expression, false) {
        Ok(ast) => ast,
        Err(e) => return Ok((atoms::error(), format!("{}", e)).encode(env)),
    };

    let result = evaluate(&scope, &ast);

    Ok((atoms::ok(), feel_value_to_term(env, &result)).encode(env))
}

/// Evaluate a FEEL unary test against an input value. The test expression
/// is wrapped as `__unary_input__ in (<expression>)` because dsntk's
/// `evaluate()` returns raw unary-test nodes rather than performing the
/// comparison directly.
/// Returns `{:ok, value}` | `{:error, reason}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn eval_unary_test<'a>(
    env: Env<'a>,
    expression: String,
    input: Term<'a>,
    context: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut feel_ctx = match term_to_feel_context(env, context) {
        Ok(ctx) => ctx,
        Err(msg) => return Ok((atoms::error(), msg).encode(env)),
    };

    let input_value = term_to_feel_value(env, input);
    let input_name: Name = "__unary_input__".into();
    feel_ctx.set_entry(&input_name, input_value);

    let wrapped_expr = format!("__unary_input__ in ({})", expression);

    let scope = FeelScope::from(feel_ctx);
    let ast = match parse_expression(&scope, &wrapped_expr, false) {
        Ok(ast) => ast,
        Err(e) => return Ok((atoms::error(), format!("{}", e)).encode(env)),
    };

    let result = evaluate(&scope, &ast);

    Ok((atoms::ok(), feel_value_to_term(env, &result)).encode(env))
}

// ---------------------------------------------------------------------------
// Elixir <-> FEEL conversion helpers
// ---------------------------------------------------------------------------

fn build_scope(env: Env, context: Term) -> Result<FeelScope, String> {
    let feel_ctx = term_to_feel_context(env, context)?;
    Ok(FeelScope::from(feel_ctx))
}

fn term_to_feel_context(env: Env, term: Term) -> Result<FeelContext, String> {
    let map: HashMap<String, Term> = term
        .decode()
        .map_err(|_| "context must be a map with string keys".to_string())?;

    let mut ctx = FeelContext::new();
    for (key, val_term) in map {
        let name: Name = key.as_str().into();
        let value = term_to_feel_value(env, val_term);
        ctx.set_entry(&name, value);
    }
    Ok(ctx)
}

fn term_to_feel_value(env: Env, term: Term) -> Value {
    if term.is_atom() {
        if let Ok(atom_str) = term.atom_to_string() {
            match atom_str.as_str() {
                "nil" => return Value::Null(None),
                "true" => return Value::Boolean(true),
                "false" => return Value::Boolean(false),
                _ => return Value::String(atom_str),
            }
        }
    }

    if let Ok(i) = term.decode::<i64>() {
        return value_number!(i);
    }

    if let Ok(f) = term.decode::<f64>() {
        let s = format!("{}", f);
        if let Ok(n) = s.parse::<FeelNumber>() {
            return Value::Number(n);
        }
        return Value::Null(Some(format!("cannot represent {} as FEEL number", f)));
    }

    if let Ok(s) = term.decode::<String>() {
        return Value::String(s);
    }

    if let Ok(list) = term.decode::<Vec<Term>>() {
        let values: Vec<Value> = list
            .into_iter()
            .map(|t| term_to_feel_value(env, t))
            .collect();
        return Value::List(values.into());
    }

    if let Ok(map) = term.decode::<HashMap<String, Term>>() {
        let mut ctx = FeelContext::new();
        for (key, val_term) in map {
            let name: Name = key.as_str().into();
            let value = term_to_feel_value(env, val_term);
            ctx.set_entry(&name, value);
        }
        return Value::Context(ctx);
    }

    Value::Null(None)
}

fn feel_value_to_term<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Null(_) => atoms::nil().encode(env),
        Value::Boolean(b) => b.encode(env),
        Value::Number(n) => {
            let s = n.to_string();
            if let Ok(i) = s.parse::<i64>() {
                i.encode(env)
            } else if let Ok(f) = s.parse::<f64>() {
                f.encode(env)
            } else {
                s.encode(env)
            }
        }
        Value::String(s) => s.encode(env),
        Value::Date(d) => {
            let s = d.to_string();
            (atoms::feel_date(), s).encode(env)
        }
        Value::Time(t) => {
            let s = t.to_string();
            (atoms::feel_time(), s).encode(env)
        }
        Value::DateTime(dt) => {
            let s = dt.to_string();
            (atoms::feel_datetime(), s).encode(env)
        }
        Value::DaysAndTimeDuration(d) => {
            let s = d.to_string();
            (atoms::feel_duration_dt(), s).encode(env)
        }
        Value::YearsAndMonthsDuration(d) => {
            let s = d.to_string();
            (atoms::feel_duration_ym(), s).encode(env)
        }
        Value::List(items) => {
            let terms: Vec<Term> = items
                .iter()
                .map(|v| feel_value_to_term(env, v))
                .collect();
            terms.encode(env)
        }
        Value::Context(ctx) => {
            let entries: Vec<(String, Term)> = ctx
                .iter()
                .map(|(name, val)| (name.to_string(), feel_value_to_term(env, val)))
                .collect();
            let map: HashMap<String, Term> = entries.into_iter().collect();
            map.encode(env)
        }
        _ => {
            let s = value.to_string();
            s.encode(env)
        }
    }
}
