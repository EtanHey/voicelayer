use rune::{Env, Key, KeyEvent, Mods, Runtime};
use voicebar_rune::*;
fn runtime() -> Runtime<Dictionary> {
    let mut rt = Runtime::new(
        Dictionary::new(fixture(), 900.0, None),
        view,
        (WIDTH, DEFAULT_HEIGHT),
        Env::new(true, 2.0),
    );
    rt.frame(0.0);
    rt
}
fn settle(rt: &mut Runtime<Dictionary>) {
    for _ in 0..80 {
        rt.frame(1.0 / 60.0);
    }
}
fn click(rt: &mut Runtime<Dictionary>, key: &str) {
    let (x, y) = rt.find(key).unwrap();
    rt.pointer_down(x, y);
    rt.pointer_up(x, y);
    settle(rt);
}
#[test]
fn plain_and_variant_rows_share_one_centre_line() {
    let mut rt = runtime();
    for id in ["term-0-0", "term-0-1"] {
        click(&mut rt, id);
        let nodes = rt.elements();
        let row = nodes.iter().find(|e| e.key.as_deref() == Some(id)).unwrap();
        let centre = row.rect[1] + row.rect[3] / 2.0;
        for part in ["text-block", "pencil", "menu"] {
            let node = nodes
                .iter()
                .find(|e| e.path.starts_with(&row.path) && e.key.as_deref() == Some(part))
                .unwrap();
            assert!(
                (node.rect[1] + node.rect[3] / 2.0 - centre).abs() <= 0.5,
                "{id}/{part}: {:?} vs {:?}",
                node.rect,
                row.rect
            );
        }
    }
    let search = rt
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("search"))
        .unwrap();
    let add = rt
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("add"))
        .unwrap();
    for (a, b) in [
        (search.rect[1], add.rect[1]),
        (search.rect[3], add.rect[3]),
        (
            search.rect[1] + search.rect[3] / 2.0,
            add.rect[1] + add.rect[3] / 2.0,
        ),
    ] {
        assert!((a - b).abs() <= 0.5);
    }
}
#[test]
fn typing_filters_terms_and_variants_and_clearing_restores_rows() {
    let mut rt = runtime();
    click(&mut rt, "search");
    rt.key(KeyEvent {
        key: Key::Text("work space".into()),
        mods: Mods::default(),
    });
    settle(&mut rt);
    assert_eq!(rt.state.matches(0), vec![1]);
    let rows: Vec<_> = rt
        .elements()
        .into_iter()
        .filter(|e| e.role == "listitem")
        .collect();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].label.as_deref(), Some("Cargo workspace"));
    rt.key(KeyEvent {
        key: Key::Command('a'),
        mods: Mods {
            cmd: true,
            ..Default::default()
        },
    });
    rt.key(KeyEvent {
        key: Key::Backspace,
        mods: Mods::default(),
    });
    settle(&mut rt);
    assert_eq!(rt.state.matches(0).len(), 4);
    assert_eq!(rt.state.matches(1).len(), 11);
    assert_eq!(
        rt.elements()
            .iter()
            .filter(|e| e.role == "listitem")
            .count(),
        15
    );
    click(&mut rt, "group-0/trigger");
    assert!(
        !rt.state.expanded[0],
        "trigger: {:?}",
        rt.elements()
            .iter()
            .filter(|e| e.path.contains("group-0"))
            .map(|e| (&e.path, e.rect, e.visible))
            .collect::<Vec<_>>()
    );
    assert!(
        !rt.elements()
            .iter()
            .any(|e| e.key.as_deref() == Some("term-0-0"))
    );
}
#[test]
fn bottom_drag_persists_and_caps_height_on_relaunch() {
    let mut rt = runtime();
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/test-state");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!("resize-{}.json", std::process::id()));
    rt.state.state_file = Some(path.clone());
    let (x, y) = rt.find("bottom-edge").unwrap();
    rt.pointer_down(x, y);
    rt.pointer_move(x, y + 200.0);
    rt.frame(0.0);
    rt.pointer_up(x, y + 200.0);
    settle(&mut rt);
    assert_eq!(rt.state.height, 840.0);
    assert_eq!(load_height(&path, 900.0), 840.0);
    assert_eq!(
        Dictionary::new(vec![], 900.0, Some(path.clone())).height,
        840.0
    );
    assert_eq!(load_height(&path, 700.0), 700.0);
    let (x, y) = rt.find("bottom-edge").unwrap();
    rt.pointer_down(x, y);
    rt.pointer_move(x, y + 5000.0);
    rt.frame(0.0);
    rt.pointer_up(x, y + 5000.0);
    settle(&mut rt);
    assert_eq!(rt.state.height, 900.0);
    assert_eq!(load_height(&path, 900.0), 900.0);
    std::fs::remove_file(path).unwrap();
}
#[test]
fn missing_malformed_and_thousand_rows_are_safe_and_virtualized() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/test-state");
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join(format!("data-{}.json", std::process::id()));
    assert!(read_entries(&path).is_empty());
    std::fs::write(&path, b"{broken").unwrap();
    assert!(read_entries(&path).is_empty());
    let entries: Vec<_> = (0..1000)
        .map(|i| Entry {
            canonical: format!("Neutral term {i}"),
            variants: vec![],
        })
        .collect();
    std::fs::write(
        &path,
        serde_json::to_vec(&serde_json::json!({"entries":entries})).unwrap(),
    )
    .unwrap();
    let state = Dictionary::new(read_entries(&path), 900.0, None);
    assert_eq!(state.personal.len(), 1000);
    let mut rt = Runtime::new(state, view, (WIDTH, DEFAULT_HEIGHT), Env::new(false, 2.0));
    rt.frame(0.0);
    assert!(
        rt.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Your terms (1000)"))
    );
    assert!(
        rt.elements()
            .iter()
            .filter(|e| e.role == "listitem")
            .count()
            < 100
    );
    let (x, y) = rt.find("viewport").unwrap();
    rt.wheel(x, y, -100000.0);
    settle(&mut rt);
    assert!(
        rt.elements()
            .iter()
            .any(|e| e.key.as_deref() == Some("term-0-999"))
    );
    assert!(
        rt.elements()
            .iter()
            .filter(|e| e.role == "listitem")
            .count()
            < 100
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn included_list_matches_typescript_canonical_and_variants_in_order() {
    // Only the public, compiled list is read. No runtime store or home-path access.
    let source = include_str!("../../src/stt-vocabulary-store.ts");
    let list = source
        .split("export const BUILTIN_STT_DICTIONARY_ENTRIES:")
        .nth(1)
        .unwrap()
        .split("\n];")
        .next()
        .unwrap();
    let entries: Vec<Entry> = list
        .lines()
        .filter(|line| line.trim().starts_with("{ canonical:"))
        .map(|line| {
            let c = line
                .split("canonical: ")
                .nth(1)
                .unwrap()
                .split(", variants:")
                .next()
                .unwrap();
            let v = line
                .split("variants: ")
                .nth(1)
                .unwrap()
                .split(" }")
                .next()
                .unwrap();
            Entry {
                canonical: serde_json::from_str(c).unwrap(),
                variants: serde_json::from_str(v).unwrap(),
            }
        })
        .collect();
    assert_eq!(included(), entries);
}

#[test]
fn menu_contains_disabled_copy_and_delete_and_cannot_mutate() {
    let mut rt = runtime();
    click(&mut rt, "term-0-0/term-0-0-actions-trigger/menu");
    assert!(rt.state.open_menu.is_some());
    let tree = rt.accessibility_json();
    fn collect(v: &serde_json::Value, labels: &mut Vec<String>) {
        if let Some(o) = v.as_object() {
            if let Some(label) = o.get("name").and_then(|v| v.as_str()) {
                if label == "Copy" || label == "Delete" {
                    let states = o.get("states").unwrap().as_array().unwrap();
                    assert!(states.iter().any(|s| s.as_str() == Some("disabled")));
                    labels.push(label.to_owned());
                }
            }
            for value in o.values() {
                collect(value, labels);
            }
        } else if let Some(a) = v.as_array() {
            for value in a {
                collect(value, labels);
            }
        }
    }
    let mut labels = vec![];
    collect(&tree, &mut labels);
    assert_eq!(labels, vec!["Copy", "Delete"], "{tree}");
    assert_eq!(rt.state.personal, fixture());
}

#[test]
fn binary_script_resizes_actual_viewport_and_relaunch_restores_height() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex")
        .join(format!("binary-resize-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state.json");
    let data = dir.join("fixture.json");
    let script = dir.join("drag.json");
    let tree = dir.join("tree.json");
    std::fs::write(&state, b"{\"height\":640}").unwrap();
    std::fs::write(
        &data,
        serde_json::to_vec(&serde_json::json!({"entries":fixture()})).unwrap(),
    )
    .unwrap();
    std::fs::write(
        &script,
        r#"[{"t":0.1,"type":"drag","key":"bottom-edge","dx":0,"dy":200,"dur":0.3}]"#,
    )
    .unwrap();
    let run = |scripted: bool| {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_voicebar-rune"));
        cmd.env_remove("VOICELAYER_RUNE_FIXTURE")
            .env("QA_VOICE_STT_VOCABULARY_PATH", &data)
            .env("VOICELAYER_RUNE_UI_STATE_PATH", &state)
            .env("VOICELAYER_RUNE_SCREEN_HEIGHT", "900")
            .arg("--tree")
            .arg(&tree)
            .args(["--at", "1.0"]);
        if scripted {
            cmd.arg("--script").arg(&script);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&tree).unwrap()).unwrap()
    };
    fn root_height(v: &serde_json::Value) -> Option<f64> {
        if v.get("key").and_then(|k| k.as_str()) == Some("dictionary") {
            return v.get("rect")?.get(3)?.as_f64();
        }
        if let Some(a) = v.as_array() {
            for e in a {
                if let Some(h) = root_height(e) {
                    return Some(h);
                }
            }
        }
        if let Some(o) = v.as_object() {
            for e in o.values() {
                if let Some(h) = root_height(e) {
                    return Some(h);
                }
            }
        }
        None
    }
    let first = run(true);
    assert_eq!(load_height(&state, 900.0), 840.0);
    assert_eq!(root_height(&first), Some(840.0), "{first}");
    let reopened = run(false);
    assert_eq!(root_height(&reopened), Some(840.0));
    std::fs::write(
        &script,
        r#"[{"t":0.1,"type":"drag","key":"bottom-edge","dx":0,"dy":5000,"dur":0.3}]"#,
    )
    .unwrap();
    let capped = run(true);
    assert_eq!(root_height(&capped), Some(900.0));
    assert_eq!(load_height(&state, 900.0), 900.0);
    for name in [state, data, script, tree] {
        std::fs::remove_file(name).unwrap();
    }
    std::fs::remove_dir(dir).unwrap();
}
