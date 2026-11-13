use rune::{Env, Key, KeyEvent, Mods, Runtime};
use voicebar_rune::settings::{self, Settings, snapshot};
fn runtime(s: Settings) -> Runtime<Settings> {
    let mut r = Runtime::new(s, settings::view, (720.0, 900.0), Env::new(true, 2.0));
    settle(&mut r);
    r
}
fn rt() -> Runtime<Settings> {
    runtime(Settings::new(snapshot::fixture(), 900.0, None))
}
fn settle(r: &mut Runtime<Settings>) {
    r.invalidate();
    for _ in 0..60 {
        r.frame(1.0 / 60.0);
    }
}
fn click(r: &mut Runtime<Settings>, key: &str) {
    let (x, y) = r.find(key).unwrap_or_else(|| panic!("missing {key}"));
    r.pointer_down(x, y);
    r.pointer_up(x, y);
    settle(r);
}
fn drag(r: &mut Runtime<Settings>, key: &str, dx: f32, dy: f32) {
    let (x, y) = r.find(key).unwrap();
    r.pointer_down(x, y);
    r.pointer_move(x + dx, y + dy);
    r.frame(0.016);
    r.pointer_up(x + dx, y + dy);
    settle(r);
}
#[test]
fn pager_keys_drag_and_history_handoff() {
    let mut r = rt();
    click(&mut r, "segment3");
    assert_eq!(r.state.tab, 3);
    r.key(KeyEvent {
        key: Key::Left,
        mods: Mods::default(),
    });
    settle(&mut r);
    assert_eq!(r.state.tab, 2);
    r.state.select_tab(0);
    settle(&mut r);
    drag(&mut r, "pager", 0.0, 140.0);
    assert_eq!(r.state.tab, 0);
    drag(&mut r, "pager", -160.0, 3.0);
    assert_eq!(r.state.tab, 1);
    r.state.select_page(4);
    settle(&mut r);
    let (x, y) = r.find("pager").unwrap();
    r.pointer_down(x, y);
    for (dx, expected) in [(-720.0, 5), (-1440.0, 6), (-2160.0, 0)] {
        r.pointer_move(x + dx, y);
        r.frame(0.016);
        assert_eq!(r.state.page(), expected);
    }
    r.pointer_up(x - 2160.0, y);
    settle(&mut r);
    r.state.select_page(4);
    settle(&mut r);
    drag(&mut r, "pager", 150.0, 0.0);
    assert_eq!(r.state.tab, 3);
}
#[test]
fn follows_pointer_and_reduce_motion() {
    let mut r = rt();
    let (x, y) = r.find("pager").unwrap();
    r.pointer_down(x, y);
    r.pointer_move(x - 40.0, y);
    r.frame(0.016);
    assert_eq!(r.state.slide, -40.0);
    r.pointer_up(x - 40.0, y);
    settle(&mut r);
    r.state.reduce_motion = true;
    settle(&mut r);
    let (x, y) = r.find("pager").unwrap();
    r.pointer_down(x, y);
    r.pointer_move(x - 40.0, y);
    r.frame(0.016);
    assert_eq!(r.state.slide, 0.0);
}
#[test]
fn setup_only_broken_and_helper_inline() {
    let mut r = rt();
    assert!(
        !r.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Setup"))
    );
    assert!(r.find("fix-f5-helper").is_none());
    r.state
        .snapshot
        .setup
        .as_mut()
        .unwrap()
        .insert("Microphone".into(), false);
    settle(&mut r);
    let texts: Vec<_> = r.elements().iter().filter_map(|e| e.text.clone()).collect();
    assert_eq!(texts.iter().filter(|t| t.as_str() == "Fix").count(), 1);
    assert!(texts.contains(&"Microphone".into()));
    r.state.snapshot.f5_helper = Some(false);
    settle(&mut r);
    let e = r.elements();
    let helper = e
        .iter()
        .find(|e| e.key.as_deref() == Some("fix-f5-helper"))
        .unwrap();
    assert!(helper.path.contains("row-dictation-key"));
    assert!(!e.iter().any(|e| e.text.as_deref() == Some("Advanced")));
}
#[test]
fn centres_and_no_prose() {
    let mut r = rt();
    for all_locked in [false, true] {
        if all_locked {
            for l in &mut r.state.snapshot.processing_locks {
                *l = Some("TEST_LOCK".into());
            }
            for l in &mut r.state.snapshot.speech_locks {
                *l = Some("TEST_LOCK".into());
            }
        }
        for tab in 0..5 {
            r.state.select_tab(tab);
            settle(&mut r);
            let es = r.elements();
            for e in &es {
                if let Some(t) = &e.text {
                    if !e.path.contains("row-first")
                        && !e.path.contains("row-continuation")
                        && !e.path.contains("row-question")
                    {
                        assert!(t.split_whitespace().count() <= 8, "{t}");
                    }
                }
            }
            for icon in es.iter().filter(|e| e.key.as_deref() == Some("lock")) {
                let parent = icon.path.rsplit_once('/').unwrap().0;
                let siblings: Vec<_> = es
                    .iter()
                    .filter(|e| {
                        e.path.rsplit_once('/').is_some_and(|(p, _)| p == parent) && e.rect[3] > 0.0
                    })
                    .collect();
                assert!(siblings.len() >= 2);
                for c in siblings {
                    assert!(
                        (icon.rect[1] + icon.rect[3] / 2.0 - c.rect[1] - c.rect[3] / 2.0).abs()
                            <= 0.5,
                        "lock {:?} control {:?}",
                        icon.rect,
                        c.rect
                    );
                }
            }
            if tab == 3 {
                let field = es
                    .iter()
                    .find(|e| e.key.as_deref() == Some("threshold"))
                    .unwrap();
                for key in ["apply", "revert"] {
                    let c = es.iter().find(|e| e.key.as_deref() == Some(key)).unwrap();
                    assert!(
                        (field.rect[1] + field.rect[3] / 2.0 - c.rect[1] - c.rect[3] / 2.0).abs()
                            <= 0.5
                    );
                }
            }
        }
    }
}
#[test]
fn height_persists_and_footer_uses_space() {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/settings-height.json");
    let _ = std::fs::remove_file(&path);
    let mut r = runtime(Settings::new(
        snapshot::fixture(),
        900.0,
        Some(path.clone()),
    ));
    drag(&mut r, "settings-bottom-edge", 0.0, 1000.0);
    assert_eq!(r.state.height, 900.0);
    assert_eq!(
        Settings::new(snapshot::fixture(), 900.0, Some(path.clone())).height,
        900.0
    );
    for tab in [0, 1, 3] {
        r.state.select_tab(tab);
        settle(&mut r);
        let e = r
            .elements()
            .into_iter()
            .find(|e| e.key.as_deref() == Some("panel-last-row"))
            .unwrap();
        assert!(
            (900.0 - 16.0 - 20.0 - e.rect[1] - e.rect[3]).abs() < 1.0,
            "{:?}",
            e.rect
        );
    }
    drag(&mut r, "settings-bottom-edge", 0.0, -2000.0);
    assert_eq!(r.state.height, settings::MIN_HEIGHT);
    std::fs::remove_file(path).unwrap();
}
#[test]
fn missing_malformed_read_only_stores() {
    let home = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/settings-home");
    let state = home.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    let p = state.join("processing-settings.json");
    let w = state.join("whisper-performance.json");
    let voice = home.join(".voicelayer/voices/Neutral/profile.yaml");
    std::fs::create_dir_all(voice.parent().unwrap()).unwrap();
    std::fs::write(
        &p,
        r#"{"model_polish":true,"outro_gate":false,"smart_chunks":false}"#,
    )
    .unwrap();
    std::fs::write(&w, r#"{"effort":"balanced"}"#).unwrap();
    std::fs::write(&voice, "name: Neutral\n").unwrap();
    let receipt = || {
        [&p, &w, &voice].map(|p| {
            (
                std::fs::read(p).unwrap(),
                std::fs::metadata(p).unwrap().modified().unwrap(),
            )
        })
    };
    let before = receipt();
    let snap = snapshot::read(&home, &Default::default());
    assert_eq!(snap.configured_effort.as_deref(), Some("balanced"));
    assert_eq!(snap.available_voices, vec!["Neutral"]);
    let mut r = runtime(Settings::new(snap, 900.0, None));
    for key in ["check-shortcut", "hide-for-1-hour", "show", "copy"] {
        click(&mut r, key);
    }
    r.state.select_tab(1);
    settle(&mut r);
    for key in ["load", "toggle-0", "toggle-1", "toggle-2"] {
        click(&mut r, key);
    }
    r.state.select_tab(3);
    settle(&mut r);
    for key in ["apply", "revert", "preview"] {
        click(&mut r, key);
    }
    assert_eq!(
        r.state.intents,
        vec![
            "intent: check-shortcut",
            "intent: hide 1h",
            "intent: show",
            "intent: copy-diagnostics",
            "intent: recognizer-toggle",
            "intent: set-processing polish=off",
            "intent: set-processing outro=on",
            "intent: set-processing smart-chunks=on",
            "intent: threshold-apply",
            "intent: threshold-revert",
            "intent: speech-preview"
        ]
    );
    assert_eq!(before, receipt());
    std::fs::write(&p, "{bad").unwrap();
    std::fs::remove_file(&w).unwrap();
    let snap = snapshot::read(&home, &Default::default());
    assert!(snap.setup.is_none());
    assert_eq!(snap.processing, [None; 3]);
    let r = runtime(Settings::new(snap, 900.0, None));
    assert!(
        r.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Unavailable here"))
    );
}
#[test]
fn environment_values_match_daemon_parsers() {
    let home = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/missing-settings-env");
    for (polish, outro, smart, expected) in [
        ("off", "false", "yes", [false, false, true]),
        ("shadow", "", "off", [true, true, false]),
        ("0", "on", "TRUE", [true, true, true]),
    ] {
        let env = [
            ("QA_VOICE_STT_POLISH".into(), polish.into()),
            ("VOICELAYER_STT_OUTRO_GATE".into(), outro.into()),
            ("VOICELAYER_STT_SMART_CHUNKS".into(), smart.into()),
        ]
        .into();
        let s = snapshot::read(&home, &env);
        assert_eq!(s.processing, expected.map(Some));
        assert!(s.processing_locks.iter().all(Option::is_some));
        assert!(s.active_effort.is_none());
    }
}
#[test]
fn binary_real_missing_and_malformed_stores_are_safe() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/settings-binary-home");
    let state = dir.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::write(state.join("processing-settings.json"), "{bad").unwrap();
    for tab in [0, 1, 3] {
        let tree = dir.join(format!("tree-{tab}.json"));
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_settings"))
            .env("HOME", &dir)
            .env("VOICELAYER_RUNE_SETTINGS_TAB", tab.to_string())
            .env("VOICELAYER_RUNE_SETTINGS_STATE", dir.join("layout.json"))
            .env_remove("QA_VOICE_STT_POLISH")
            .env_remove("VOICELAYER_STT_OUTRO_GATE")
            .env_remove("VOICELAYER_STT_SMART_CHUNKS")
            .args(["--real", "--tree"])
            .arg(&tree)
            .args(["--at", "1"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let tree = std::fs::read_to_string(tree).unwrap();
        assert!(tree.contains("Unavailable here"));
    }
}
#[test]
fn all_profile_menus_and_fixture_controls_emit_only_intents() {
    let mut r = rt();
    for key in [
        "check-shortcut",
        "hide-for-1-hour",
        "show",
        "make-default",
        "copy",
    ] {
        click(&mut r, key);
    }
    r.state.select_tab(3);
    settle(&mut r);
    for key in ["Short-voice", "Short-rate", "Long-voice", "Long-rate"] {
        click(&mut r, key);
        let es = r.elements();
        let pick = es
            .iter()
            .find(|e| {
                e.text.as_deref()
                    == Some(if key.ends_with("voice") {
                        "Meadow"
                    } else {
                        "+20%"
                    })
                    && e.visible[3] > 0.0
            })
            .unwrap();
        let x = pick.rect[0] + pick.rect[2] / 2.0;
        let y = pick.rect[1] + pick.rect[3] / 2.0;
        r.pointer_down(x, y);
        r.pointer_up(x, y);
        settle(&mut r);
    }
    let expected = [
        "intent: check-shortcut",
        "intent: hide 1h",
        "intent: show",
        "intent: microphone-default 0",
        "intent: copy-diagnostics",
        "intent: set-Short-voice Meadow",
        "intent: set-Short-rate +20%",
        "intent: set-Long-voice Meadow",
        "intent: set-Long-rate +20%",
    ];
    assert_eq!(r.state.intents, expected);
    assert_eq!(
        r.state.snapshot.voices,
        [Some("Garden".into()), Some("Brook".into())]
    );
}
#[test]
fn taller_embedded_lists_mount_more_rows_to_bottom() {
    let mut r = rt();
    for tab in [2, 4] {
        let mut counts = vec![];
        for height in [640.0, 900.0] {
            r.viewport = (720.0, height);
            r.state.select_tab(tab);
            settle(&mut r);
            let es = r.elements();
            let rows: Vec<_> = es
                .iter()
                .filter(|e| e.role == "listitem" && e.visible[3] > 0.0 && e.visible[2] > 0.0)
                .collect();
            assert!(!rows.is_empty());
            let last = rows.last().unwrap();
            let viewport = es
                .iter()
                .find(|e| e.key.as_deref() == Some("viewport"))
                .unwrap();
            let bottom = last.visible[1] + last.visible[3];
            assert!(
                viewport.rect[1] + viewport.rect[3] - bottom <= last.rect[3] + 1.0,
                "tab {tab} last {:?} viewport {:?}",
                last.rect,
                viewport.rect
            );
            counts.push(rows.len());
        }
        assert!(counts[1] > counts[0], "tab {tab}: {counts:?}");
    }
}
#[test]
fn binary_bottom_drag_resizes_and_relaunches() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/settings-binary-resize");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("layout.json");
    std::fs::write(&path, r#"{"height":540}"#).unwrap();
    let script = dir.join("drag.json");
    std::fs::write(
        &script,
        r#"[{"t":0.1,"type":"drag","key":"settings-bottom-edge","dx":0,"dy":2000,"dur":0.3}]"#,
    )
    .unwrap();
    for scripted in [true, false] {
        let tree = dir.join("tree.json");
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_settings"));
        cmd.env("VOICELAYER_RUNE_SETTINGS_STATE", &path)
            .env("VOICELAYER_RUNE_SCREEN_HEIGHT", "900")
            .arg("--tree")
            .arg(&tree)
            .args(["--at", "1"]);
        if scripted {
            cmd.arg("--script").arg(&script);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let tree: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&tree).unwrap()).unwrap();
        fn height(v: &serde_json::Value) -> Option<f64> {
            if v["key"].as_str() == Some("settings") {
                return v["rect"][3].as_f64();
            }
            match v {
                serde_json::Value::Object(o) => o.values().find_map(height),
                serde_json::Value::Array(a) => a.iter().find_map(height),
                _ => None,
            }
        }
        assert_eq!(height(&tree), Some(900.0));
        assert_eq!(voicebar_rune::load_height(&path, 900.0), 900.0);
    }
}
#[test]
fn complete_cycle_release_keeps_wrapped_page() {
    let mut r = rt();
    drag(&mut r, "pager", -5040.0, 0.0);
    assert_eq!(r.state.page(), 0);
}
