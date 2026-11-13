use rune::{Env, Runtime};
use voicebar_rune::settings::{self, Settings, snapshot};
fn rt() -> Runtime<Settings> {
    let mut r = Runtime::new(
        Settings::new(snapshot::fixture(), 900., None),
        settings::view,
        (720., 640.),
        Env::new(true, 2.),
    );
    settle(&mut r);
    r
}
fn settle(r: &mut Runtime<Settings>) {
    r.invalidate();
    for _ in 0..60 {
        r.frame(1. / 60.);
    }
}
fn heading(r: &Runtime<Settings>, name: &str) -> f32 {
    r.elements()
        .iter()
        .find(|e| e.text.as_deref() == Some(name))
        .unwrap()
        .rect[0]
}
#[test]
fn short_release_continuous_monotonic() {
    for (page, dx, name) in [(0, -160., "Recognizer"), (1, 160., "Controls")] {
        let mut r = rt();
        r.state.select_page(page);
        settle(&mut r);
        let (x, y) = r.find("pager").unwrap();
        r.pointer_down(x, y);
        for i in 1..=10 {
            r.pointer_move(x + dx * i as f32 / 10., y);
            r.frame(1. / 60.);
        }
        let before = heading(&r, name);
        r.pointer_up(x + dx, y);
        r.frame(0.);
        let mut last = heading(&r, name);
        assert!((before - last).abs() <= 1., "release {before} -> {last}");
        for _ in 0..30 {
            r.frame(1. / 60.);
            let now = heading(&r, name);
            assert!((now - last) * dx >= -0.5, "reversed {last} -> {now}");
            last = now;
        }
    }
}
#[test]
fn ends_never_wrap() {
    let mut r = rt();
    let (x, y) = r.find("pager").unwrap();
    r.pointer_down(x, y);
    let mut tab = 0;
    for i in 1..=70 {
        r.pointer_move(x - 5040. * i as f32 / 70., y);
        r.frame(1. / 60.);
        assert!(r.state.tab.abs_diff(tab) <= 1);
        tab = r.state.tab;
    }
    r.pointer_up(x - 5040., y);
    settle(&mut r);
    assert_eq!(r.state.page(), 6);
    r.state.select_page(0);
    settle(&mut r);
    let rest = heading(&r, "Controls");
    let (x, y) = r.find("pager").unwrap();
    r.pointer_down(x, y);
    r.pointer_move(x + 400., y);
    r.frame(0.016);
    assert_eq!(r.state.page(), 0);
    assert!(r.state.slide > 0. && r.state.slide < 400.);
    r.pointer_up(x + 400., y);
    settle(&mut r);
    assert!((heading(&r, "Controls") - rest).abs() < 0.5);
}
#[test]
fn unknown_has_no_switch() {
    let mut r = rt();
    r.state.snapshot.processing = [None; 3];
    r.state.select_tab(1);
    settle(&mut r);
    let es = r.elements();
    assert!(
        !es.iter()
            .any(|e| e.key.as_deref().is_some_and(|k| k.starts_with("toggle-")))
    );
    assert_eq!(
        es.iter()
            .filter(|e| e.text.as_deref() == Some("Unavailable here"))
            .count(),
        3
    );
}
#[test]
fn truthful_redundant_controls() {
    let mut r = rt();
    assert!(r.find("hide-for-1-hour").is_some());
    assert!(r.find("show").is_none());
    r.state.snapshot.visible = Some(false);
    settle(&mut r);
    assert!(r.find("show").is_some());
    assert!(r.find("hide-for-1-hour").is_none());
    r.state.select_tab(1);
    settle(&mut r);
    let es = r.elements();
    assert_eq!(
        es.iter()
            .filter(|e| e.text.as_deref() == Some("Configured"))
            .count(),
        1
    );
    assert!(!es.iter().any(|e| e.text.as_deref() == Some("Read-only")));
    r.state.select_tab(3);
    settle(&mut r);
    assert!(r.find("apply").is_none());
    assert!(r.find("revert").is_none());
    r.state.threshold = rune::TextEdit::new("450");
    settle(&mut r);
    assert!(r.find("apply").is_some());
    assert!(r.find("revert").is_some());
}
#[test]
fn daemon_format_and_invalid_effort() {
    let dir =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-parser-home");
    let state = dir.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    for (raw, expected) in [
        ("\"off\"", Some(false)),
        ("\"on\"", Some(true)),
        ("true", None),
    ] {
        std::fs::write(
            state.join("processing-settings.json"),
            format!("{{\"model_polish\":{raw}}}"),
        )
        .unwrap();
        let s = snapshot::read(&dir, &Default::default());
        assert_eq!(s.processing[0], expected);
    }
    std::fs::write(
        state.join("whisper-performance.json"),
        r#"{"effort":"balanced"}"#,
    )
    .unwrap();
    let env = [("QA_VOICE_WHISPER_PERFORMANCE_EFFORT".into(), "bad".into())].into();
    let s = snapshot::read(&dir, &env);
    assert_eq!(s.configured_effort.as_deref(), Some("balanced"));
    assert!(s.effort_lock.is_none());
    let env = [("QA_VOICE_STT_POLISH".into(), "shadow".into())].into();
    let s = snapshot::read(&dir, &env);
    assert_eq!(s.polish, Some(snapshot::Polish::Shadow));
    let mut r = rt();
    r.state.snapshot = s;
    r.state.select_tab(1);
    settle(&mut r);
    assert!(r.find("toggle-0").is_none());
    assert!(
        r.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Shadow"))
    );
}
#[test]
fn fixed_group_gaps_at_both_heights() {
    let mut r = rt();
    for tab in [0, 1, 3] {
        let mut positions = vec![];
        for h in [640., 900.] {
            r.set_viewport((720., h), 2.);
            r.state.select_tab(tab);
            settle(&mut r);
            let es = r.elements();
            let groups: Vec<_> = es
                .iter()
                .filter(|e| e.key.as_deref().is_some_and(|k| k.starts_with("group-")))
                .collect();
            assert!(groups.len() >= 3);
            for pair in groups.windows(2) {
                assert!(
                    (pair[1].rect[1] - pair[0].rect[1] - pair[0].rect[3] - settings::GROUP_GAP)
                        .abs()
                        < 0.5,
                    "tab {tab}: {:?} {:?}",
                    pair[0].rect,
                    pair[1].rect
                );
            }
            positions.push(groups.last().unwrap().rect);
            for e in es
                .iter()
                .filter(|e| e.key.as_deref().is_some_and(|k| k.starts_with("row-")))
            {
                assert!(e.rect[2] <= 560.5);
            }
        }
        assert_eq!(positions[0], positions[1]);
    }
}
#[test]
fn binary_controls_are_read_only_and_revision_bound() {
    let dir =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-control-home");
    let state = dir.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    let p = state.join("processing-settings.json");
    let w = state.join("whisper-performance.json");
    let v = dir.join(".voicelayer/voices/Neutral/profile.yaml");
    std::fs::create_dir_all(v.parent().unwrap()).unwrap();
    std::fs::write(
        &p,
        r#"{"model_polish":"off","outro_gate":true,"smart_chunks":false}"#,
    )
    .unwrap();
    std::fs::write(&w, r#"{"effort":"balanced"}"#).unwrap();
    std::fs::write(&v, "name: Neutral\n").unwrap();
    let receipt = || {
        [&p, &w, &v].map(|p| {
            (
                std::fs::read(p).unwrap(),
                std::fs::metadata(p).unwrap().modified().unwrap(),
            )
        })
    };
    let before = receipt();
    let keys = [
        "check-shortcut",
        "hide-for-1-hour",
        "make-default-1",
        "copy-diagnostics",
        "segment1",
        "unload",
        "toggle-0",
        "toggle-1",
        "toggle-2",
        "segment3",
        "Short-voice",
        "option2",
        "Short-rate-minus",
        "Short-rate-plus",
        "Long-voice",
        "option2",
        "Long-rate-minus",
        "Long-rate-plus",
        "threshold-text",
    ];
    let mut events = vec![];
    for (i, k) in keys.iter().enumerate() {
        events.push(serde_json::json!({"t":0.1+i as f32*0.15,"type":"click","key":k}));
    }
    let t = 0.1 + keys.len() as f32 * 0.15;
    events.push(serde_json::json!({"t":t,"type":"type","text":"5"}));
    events.push(serde_json::json!({"t":t+0.15,"type":"click","key":"apply"}));
    events.push(serde_json::json!({"t":t+0.3,"type":"click","key":"revert"}));
    events.push(serde_json::json!({"t":t+0.45,"type":"click","key":"preview"}));
    for (i, key) in [
        "segment2",
        "add",
        "pencil",
        "segment4",
        "entry-0",
        "action-play",
        "action-copy",
        "action-paste",
        "action-re-transcribe",
    ]
    .iter()
    .enumerate()
    {
        events.push(serde_json::json!({"t":t+0.65+i as f32*0.15,"type":"click","key":key}));
    }
    let script = dir.join("controls.json");
    std::fs::write(&script, serde_json::to_vec(&events).unwrap()).unwrap();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_settings"))
        .env("HOME", &dir)
        .env("VOICELAYER_RUNE_SETTINGS_STATE", dir.join("layout.json"))
        .args(["--script"])
        .arg(script)
        .args(["--tree"])
        .arg(dir.join("tree.json"))
        .args(["--at", "7"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    for expected in [
        "set-visibility from=shown to=hidden-1h rev=7",
        "set-processing polish from=on to=off rev=7",
        "set-Short-rate from=+0% to=+5% rev=7",
        "set-Short-voice from=Garden to=Meadow rev=7",
        "set-Long-voice from=Brook to=Meadow rev=7",
        "add-term",
        "edit-term",
        "re-transcribe",
        "set-threshold from=400 to=",
    ] {
        assert!(stdout.contains(expected), "missing {expected}: {stdout}");
    }
    // A second binary session covers mutually exclusive repairs and all menu actions.
    let mut more = vec![];
    let mut at = 0.1;
    let mut click = |key: String| {
        more.push(serde_json::json!({"t":at,"type":"click","key":key}));
        at += 0.2;
    };
    for key in [
        "row-microphone/fix",
        "row-accessibility/fix",
        "row-input-monitoring/fix",
        "row-f5-listener/fix",
        "fix-f5-helper",
        "show",
        "segment1",
        "load",
        "toggle-0",
        "toggle-1",
        "toggle-2",
        "segment2",
        "menu",
        "term-0-0-actions-item0",
        "menu",
        "term-0-0-actions-item1",
        "segment4",
    ] {
        click(key.into());
    }
    for i in 0..6 {
        click("row-menu".into());
        click(format!("history-menu-item{i}"));
    }
    drop(click);
    let script = dir.join("repairs.json");
    std::fs::write(&script, serde_json::to_vec(&more).unwrap()).unwrap();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_settings"))
        .env("HOME", &dir)
        .env("VOICELAYER_RUNE_SETTINGS_STATE", dir.join("layout.json"))
        .env("VOICELAYER_RUNE_SETTINGS_REPAIRS", "1")
        .args(["--script"])
        .arg(script)
        .args(["--tree"])
        .arg(dir.join("repair-tree.json"))
        .arg("--at")
        .arg((at + 0.5).to_string())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    for expected in [
        "fix microphone",
        "fix accessibility",
        "fix input-monitoring",
        "fix f5-listener",
        "fix-f5-helper",
        "set-visibility from=hidden to=shown rev=7",
        "set-residency from=unloaded to=loaded rev=7",
        "set-processing polish from=off to=on rev=7",
        "set-processing outro from=on to=off rev=7",
        "set-processing smart-chunks from=on to=off rev=7",
        "copy-term",
        "delete-term",
        "copy-id",
        "copy-logs",
        "open-logs",
        "more-info",
    ] {
        assert!(stdout.contains(expected), "missing {expected}: {stdout}");
    }
    assert_eq!(receipt(), before);
}
#[test]
fn no_prose_every_page_menu_and_tooltip() {
    let mut r = rt();
    for page in 0..7 {
        r.state.select_page(page);
        settle(&mut r);
        for open in [None, Some("Short-voice"), Some("Long-voice")] {
            if page == 3 {
                r.state.open = open.map(str::to_owned);
                settle(&mut r);
            }
            let es = r.elements();
            for e in &es {
                if let Some(t) = &e.text {
                    let exempt = matches!(
                        e.key.as_deref(),
                        Some("row-first" | "row-continuation" | "row-question")
                    );
                    if !exempt {
                        assert!(
                            t.split_whitespace().count() <= 8,
                            "page {page} {}: {t}",
                            e.path
                        );
                    }
                }
            }
            for e in es.iter().filter(|e| e.key.as_deref() == Some("lock")) {
                r.pointer_move(e.rect[0] + 7., e.rect[1] + 7.);
                for _ in 0..90 {
                    r.frame(1. / 60.);
                }
                for e in r.elements() {
                    if let Some(t) = e.text {
                        assert!(
                            t.split_whitespace().count() <= 8
                                || matches!(
                                    e.key.as_deref(),
                                    Some("row-first" | "row-continuation" | "row-question")
                                ),
                            "tooltip: {t}"
                        );
                    }
                }
            }
        }
    }
}
#[test]
fn binary_resize_changes_lists_and_keeps_form_groups() {
    let dir =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-resize-proof");
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("drag.json");
    std::fs::write(
        &script,
        r#"[{"t":0.1,"type":"drag","key":"settings-bottom-edge","dx":0,"dy":260,"dur":0.3}]"#,
    )
    .unwrap();
    for tab in 0..5 {
        let mut facts = vec![];
        for resize in [false, true] {
            let state = dir.join("layout.json");
            std::fs::write(&state, r#"{"height":640}"#).unwrap();
            let tree = dir.join("tree.json");
            let mut c = std::process::Command::new(env!("CARGO_BIN_EXE_settings"));
            c.env("VOICELAYER_RUNE_SETTINGS_STATE", &state)
                .env("VOICELAYER_RUNE_SETTINGS_TAB", tab.to_string())
                .env("VOICELAYER_RUNE_SCREEN_HEIGHT", "900")
                .args(["--tree"])
                .arg(&tree)
                .args(["--at", "1"]);
            if resize {
                c.arg("--script").arg(&script);
            }
            let out = c.output().unwrap();
            assert!(out.status.success());
            let tree: serde_json::Value =
                serde_json::from_slice(&std::fs::read(tree).unwrap()).unwrap();
            let es = tree["elements"].as_array().unwrap();
            let root = es.iter().find(|e| e["key"] == "settings").unwrap();
            assert_eq!(
                root["rect"][3].as_f64().unwrap(),
                if resize { 900. } else { 640. }
            );
            if tab == 2 || tab == 4 {
                let rows = es
                    .iter()
                    .filter(|e| {
                        e["role"] == "listitem"
                            && e["rect"][1].as_f64().unwrap() < if resize { 884. } else { 624. }
                            && e["rect"][1].as_f64().unwrap() + e["rect"][3].as_f64().unwrap()
                                > 100.
                    })
                    .count();
                facts.push(serde_json::json!(rows));
            } else {
                facts.push(
                    es.iter()
                        .filter(|e| e["key"].as_str().is_some_and(|k| k.starts_with("group-")))
                        .last()
                        .unwrap()["rect"]
                        .clone(),
                );
            }
        }
        if tab == 2 || tab == 4 {
            assert!(
                facts[1].as_u64() > facts[0].as_u64(),
                "tab {tab}: {facts:?}"
            );
        } else {
            assert_eq!(facts[0], facts[1]);
        }
    }
}
#[test]
fn binary_real_uses_daemon_rows() {
    let home =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-real-rows");
    let state = home.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::write(
        state.join("processing-settings.json"),
        r#"{"model_polish":"off"}"#,
    )
    .unwrap();
    std::fs::write(
        state.join("whisper-performance.json"),
        r#"{"effort":"balanced"}"#,
    )
    .unwrap();
    let tree = home.join("tree.json");
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_settings"))
        .env("HOME", &home)
        .env("VOICELAYER_RUNE_SETTINGS_STATE", home.join("layout.json"))
        .env("VOICELAYER_RUNE_SETTINGS_TAB", "1")
        .env_remove("QA_VOICE_STT_POLISH")
        .env_remove("QA_VOICE_WHISPER_PERFORMANCE_EFFORT")
        .args(["--real", "--tree"])
        .arg(&tree)
        .args(["--at", "1"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let tree: serde_json::Value = serde_json::from_slice(&std::fs::read(tree).unwrap()).unwrap();
    fn polish_node(v: &serde_json::Value) -> Option<&serde_json::Value> {
        if v["key"] == "toggle-0" {
            return Some(v);
        }
        match v {
            serde_json::Value::Object(o) => o.values().find_map(polish_node),
            serde_json::Value::Array(a) => a.iter().find_map(polish_node),
            _ => None,
        }
    }
    assert!(
        polish_node(&tree["accessibility"]).unwrap()["states"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s == "unchecked")
    );
    let es = tree["elements"].as_array().unwrap();
    assert!(es.iter().any(|e| e["key"] == "toggle-0"));
    assert!(es.iter().any(|e| e["text"] == "balanced"));
    let local: Vec<_> = es
        .iter()
        .filter(|e| {
            e["path"]
                .as_str()
                .is_some_and(|p| p.split('/').any(|id| id == "row-local-recognizer"))
        })
        .collect();
    assert!(local.iter().any(|e| e["text"] == "Unavailable here"));
    assert!(!local.iter().any(|e| e["key"] == "load"));
    assert_eq!(
        snapshot::read(&home, &Default::default()).processing[0],
        Some(false)
    );
}

#[test]
fn hosted_menus_and_default_row_have_precise_roles() {
    let mut r = rt();
    let es = r.elements();
    assert!(
        !es.iter()
            .filter(|e| e.path.split('/').any(|id| id == "microphone-0"))
            .any(|e| e.text.as_deref() == Some("Make default"))
    );
    for page in [2, 4, 5, 6] {
        r.state.select_page(page);
        settle(&mut r);
        let key = if page == 2 { "menu" } else { "row-menu" };
        let (x, y) = r.find(key).unwrap();
        r.pointer_down(x, y);
        r.pointer_up(x, y);
        settle(&mut r);
        for e in r.elements() {
            if let Some(t) = e.text {
                assert!(
                    t.split_whitespace().count() <= 8
                        || matches!(
                            e.key.as_deref(),
                            Some("row-first" | "row-continuation" | "row-question")
                        ),
                    "menu {page}: {t}"
                );
            }
        }
        r.state.dictionary.open_menu = None;
        r.state.history.menu = None;
    }
}

#[test]
fn fresh_flick_from_every_page() {
    let mut r = rt();
    for page in 0..6 {
        r.state.select_page(page);
        settle(&mut r);
        let (x, y) = r.find("pager").unwrap();
        r.pointer_down(x, y);
        r.pointer_move(x - 160., y);
        r.frame(0.016);
        r.pointer_up(x - 160., y);
        settle(&mut r);
        assert_eq!(r.state.page(), page + 1, "starting page {page}");
    }
}
