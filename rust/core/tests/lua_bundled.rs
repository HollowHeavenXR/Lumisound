//! LUMI_LUA_DIR=ios/Lumisound/Resources cargo test -p lumisound-core --test lua_bundled -- --nocapture
#[test]
fn bundled_scripts_run() {
    let Ok(dir) = std::env::var("LUMI_LUA_DIR") else { return };
    for (sub, global) in [("LuaPresets", "theme"), ("LuaEffects", "effect"), ("LuaVisualizers", "visualizer")] {
        for e in std::fs::read_dir(format!("{dir}/{sub}")).unwrap().flatten() {
            let src = std::fs::read_to_string(e.path()).unwrap();
            let prelude = if sub == "LuaEffects" { "local track = json.decode('{\"title\":\"t\",\"artist\":\"a\",\"genre\":\"Rock\",\"bpm\":120}')\n" } else { "" };
            let r = lumisound_core::lua::lua_eval_string(format!("{prelude}{src}\nreturn json.encode({global})\n"), e.file_name().to_string_lossy().into());
            println!("{sub}/{}: {}", e.file_name().to_string_lossy(), match &r { Ok(s) => format!("ok ({} bytes)", s.len()), Err(err) => format!("ERR {err}") });
            assert!(r.is_ok());
        }
    }
}
