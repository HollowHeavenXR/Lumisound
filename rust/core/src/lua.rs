//! Lua scripting for themes, effects, visualizers, smart playlists and the
//! track-vault rules: a sandboxed Lua 5.4 (no io/os/package/debug), a `json`
//! module (encode/decode), and a wall-clock budget so a runaway user script
//! can't hang the app. Scripts return a JSON string the app decodes.

use crate::error::{CoreError, CoreResult};
use mlua::{Lua, LuaOptions, LuaSerdeExt, StdLib, Value};
use std::time::{Duration, Instant};

const BUDGET: Duration = Duration::from_secs(3);

fn new_state() -> mlua::Result<Lua> {
    let lua = Lua::new_with(StdLib::MATH | StdLib::STRING | StdLib::TABLE | StdLib::UTF8 | StdLib::COROUTINE, LuaOptions::default())?;
    let json = lua.create_table()?;
    json.set(
        "encode",
        lua.create_function(|lua, v: Value| {
            let j: serde_json::Value = lua.from_value_with(v, mlua::DeserializeOptions::new().encode_empty_tables_as_array(true))?;
            serde_json::to_string(&j).map_err(mlua::Error::external)
        })?,
    )?;
    json.set(
        "decode",
        lua.create_function(|lua, s: String| {
            let j: serde_json::Value = serde_json::from_str(&s).map_err(mlua::Error::external)?;
            lua.to_value_with(&j, mlua::SerializeOptions::new().serialize_none_to_null(false))
        })?,
    )?;
    lua.globals().set("json", json)?;
    let start = Instant::now();
    lua.set_hook(mlua::HookTriggers::new().every_nth_instruction(10_000), move |_lua, _dbg| {
        if start.elapsed() > BUDGET {
            Err(mlua::Error::RuntimeError("script took too long".into()))
        } else {
            Ok(mlua::VmState::Continue)
        }
    });
    Ok(lua)
}

/// Run `source` and return the string it evaluates to (scripts end with
/// `return json.encode(...)`).
#[uniffi::export]
pub fn lua_eval_string(source: String, chunk_name: String) -> CoreResult<String> {
    let lua = new_state().map_err(|e| CoreError::invalid(e.to_string()))?;
    let v: Value = lua.load(&source).set_name(chunk_name).eval().map_err(|e| CoreError::invalid(e.to_string()))?;
    match v {
        Value::String(s) => Ok(s.to_str().map_err(|e| CoreError::invalid(e.to_string()))?.to_string()),
        other => Err(CoreError::invalid(format!("script returned {} instead of a JSON string", other.type_name()))),
    }
}

/// Escape `s` as a double-quoted Lua string literal.
#[uniffi::export]
pub fn lua_quote(s: String) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\{}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn runs_json_scripts_and_limits_time() {
        let r = lua_eval_string("local t = json.decode('[1,2,3]'); local m = {}; for i=1,#t do if t[i] > 1 then table.insert(m, t[i]) end end; return json.encode(m)".into(), "t".into()).unwrap();
        assert_eq!(r, "[2,3]");
        assert_eq!(lua_eval_string("return json.encode({})".into(), "t".into()).unwrap(), "[]");
        assert_eq!(lua_eval_string("theme = {name='x', n=math.floor(2.7)}; return json.encode(theme)".into(), "t".into()).unwrap().len() > 5, true);
        assert!(lua_eval_string("return io.open('x')".into(), "t".into()).is_err());
        assert!(lua_eval_string("while true do end".into(), "t".into()).is_err());
        assert_eq!(lua_quote("a\"b\n".into()), "\"a\\\"b\\n\"");
    }
}
