use rune::{Env, Key, KeyEvent, Mods, Runtime};
use voicebar_rune::history::{self, History};
fn rt() -> Runtime<History> {
    let mut r = Runtime::new(
        History::new(history::fixture()),
        history::view,
        (720.0, 720.0),
        Env::new(true, 2.0),
    );
    r.on_key = Some(history::key);
    r.frame(0.0);
    settle(&mut r);
    r
}
fn settle(r: &mut Runtime<History>) {
    r.invalidate();
    for _ in 0..90 {
        r.frame(1.0 / 60.0);
    }
}
fn click(r: &mut Runtime<History>, k: &str) {
    let (x, y) = r.find(k).unwrap_or_else(|| panic!("missing {k}"));
    r.pointer_down(x, y);
    r.pointer_up(x, y);
    settle(r);
}
fn key(r: &mut Runtime<History>, k: Key) {
    r.key(KeyEvent {
        key: k,
        mods: Mods::default(),
    });
    settle(r);
}
fn drag(r: &mut Runtime<History>, k: &str, dx: f32, dy: f32) {
    let (x, y) = r.find(k).unwrap();
    r.pointer_down(x, y);
    r.pointer_move(x + dx, y + dy);
    r.frame(0.016);
    r.pointer_up(x + dx, y + dy);
    settle(r);
}
#[test]
fn width() {
    let mut r = rt();
    for width in [420.0, 720.0, 1000.0] {
        r.viewport = (width, 720.0);
        settle(&mut r);
        let es = r.elements();
        for row in es
            .iter()
            .filter(|e| e.role == "listitem" && e.visible[2] > 0.0 && e.visible[3] > 0.0)
        {
            let text = es
                .iter()
                .find(|e| e.path.starts_with(&row.path) && e.key.as_deref() == Some("row-text"))
                .unwrap();
            let time = es
                .iter()
                .find(|e| e.path.starts_with(&row.path) && e.key.as_deref() == Some("row-time"))
                .unwrap();
            assert!(
                text.rect[2] >= (row.rect[2] - 24.0) * 0.70,
                "text {:?} row {:?}",
                text.rect,
                row.rect
            );
            assert!(
                (time.rect[0] + time.rect[2] - (row.rect[0] + row.rect[2] - 12.0)).abs() < 12.0
            );
            assert!((text.rect[1] - time.rect[1]).abs() < 0.5);
        }
    }
}
#[test]
fn expand_and_intents_are_read_only() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
    let snapshot = || {
        let mut v = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| {
                let e = e.unwrap();
                (e.file_name(), e.metadata().unwrap().modified().unwrap())
            })
            .collect::<Vec<_>>();
        v.sort();
        v
    };
    let before = snapshot();
    let mut r = rt();
    click(&mut r, "entry-0");
    assert_eq!(r.state.expanded, Some(0));
    let nodes = r.elements();
    let row = nodes
        .iter()
        .find(|e| e.key.as_deref() == Some("entry-0"))
        .unwrap();
    let body = nodes
        .iter()
        .find(|e| e.path.starts_with(&row.path) && e.key.as_deref() == Some("row-text"))
        .unwrap();
    assert!(
        body.rect[3] > 45.0,
        "expanded body must wrap to display the full fixture"
    );
    assert!(body.rect[0] + body.rect[2] <= row.rect[0] + row.rect[2] - 12.0);
    for verb in ["play", "copy", "paste", "re-transcribe"] {
        click(&mut r, &format!("action-{verb}"));
        assert!(
            r.state
                .intents
                .last()
                .unwrap()
                .starts_with(&format!("intent {verb}"))
        );
    }
    assert_eq!(
        r.elements()
            .iter()
            .filter(|e| e.key.as_deref() == Some("row-actions"))
            .count(),
        1
    );
    click(&mut r, "entry-1");
    assert_eq!(r.state.expanded, Some(1));
    key(&mut r, Key::Escape);
    assert_eq!(r.state.expanded, None);
    assert_eq!(before, snapshot());
}
#[test]
fn selector() {
    let mut r = rt();
    click(&mut r, "segment1");
    assert_eq!(r.state.category, 1);
    key(&mut r, Key::Right);
    assert_eq!(r.state.category, 2);
    key(&mut r, Key::Left);
    assert_eq!(r.state.category, 1);
    drag(&mut r, "viewport", -100.0, 2.0);
    assert_eq!(r.state.category, 2);
    drag(&mut r, "viewport", 100.0, 200.0);
    assert_eq!(r.state.category, 2);

    for reduce in [false, true] {
        r.state.reduce_motion = reduce;
        let (x, y) = r.find("viewport").unwrap();
        r.pointer_down(x, y);
        r.pointer_move(x + 45.0, y);
        r.frame(0.016);
        assert_eq!(r.state.slide, if reduce { 0.0 } else { 45.0 });
        let content = r
            .elements()
            .into_iter()
            .find(|e| e.key.as_deref() == Some("list-content"))
            .unwrap();
        let viewport = r
            .elements()
            .into_iter()
            .find(|e| e.key.as_deref() == Some("viewport"))
            .unwrap();
        assert!(
            (content.rect[0] - viewport.rect[0] - if reduce { 0.0 } else { 45.0 }).abs() < 0.5,
            "content {:?} viewport {:?}, slide {}",
            content.rect,
            viewport.rect,
            r.state.slide
        );
        r.pointer_up(x + 45.0, y);
        settle(&mut r);
    }
}
#[test]
fn older() {
    let mut r = rt();
    r.state.lists[0].extend(history::fixture()[0].clone());
    settle(&mut r);
    assert_eq!(r.state.count(), 20);
    let (x, y) = r.find("viewport").unwrap();
    r.wheel(x, y, -100000.0);
    settle(&mut r);
    click(&mut r, "load-older");
    assert_eq!(r.state.count(), 40);
    r.wheel(x, y, -100000.0);
    settle(&mut r);
    click(&mut r, "load-older");
    assert_eq!(r.state.count(), 60);
    assert!(r.find("load-older").is_none());
}
#[test]
fn badge() {
    let mut r = rt();
    let (vx, vy) = r.find("viewport").unwrap();
    r.wheel(vx, vy, -100000.0);
    settle(&mut r);
    let (x, y) = r.find("pull-zone").unwrap();
    r.pointer_down(x, y);
    let mut last = 0.0;
    for i in 0..=20 {
        r.pointer_move(x, y + i as f32 * 5.0);
        settle(&mut r);
        let e = r
            .elements()
            .into_iter()
            .find(|e| e.key.as_deref() == Some("settings-handle"))
            .unwrap();
        assert!(e.rect[2] >= last - 0.01);
        last = e.rect[2];
    }
    let es = r.elements();
    let badge = es
        .iter()
        .find(|e| e.key.as_deref() == Some("settings-handle"))
        .unwrap();
    let label = es
        .iter()
        .find(|e| e.key.as_deref() == Some("badge-text"))
        .unwrap();
    assert!(
        (badge.rect[1] + badge.rect[3] / 2.0 - label.rect[1] - label.rect[3] / 2.0).abs() <= 0.5
    );
    assert!((last - 240.0).abs() < 0.1);
    r.pointer_up(x, y + 100.0);
    settle(&mut r);
    assert_eq!(r.state.intents, vec!["intent open-settings"]);
    drag(&mut r, "pull-zone", 0.0, 50.0);
    assert_eq!(r.state.intents.len(), 1);
    let e = r
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("settings-handle"))
        .unwrap();
    assert!((e.rect[2] - 40.0).abs() < 0.1);
}
#[test]
fn missing_bad_and_large() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/history-bad");
    assert!(history::archive::load(&root).iter().all(Vec::is_empty));
    let entry = root.join("2026-11-13/broken");
    std::fs::create_dir_all(&entry).unwrap();
    std::fs::write(entry.join("metadata.json"), "broken").unwrap();
    assert!(history::archive::load(&root).iter().all(Vec::is_empty));
    std::fs::remove_file(entry.join("metadata.json")).unwrap();
    std::fs::remove_dir(&entry).unwrap();
    std::fs::remove_dir(entry.parent().unwrap()).unwrap();
    std::fs::remove_dir(root).unwrap();
    let mut r = rt();
    r.state.lists[0] = (0..2000)
        .map(|i| {
            let mut e = history::fixture()[0][0].clone();
            e.id = format!("fixture-{i}");
            e
        })
        .collect();
    r.state.limits[0] = 2000;
    settle(&mut r);
    assert!(r.elements().iter().filter(|e| e.role == "listitem").count() < 100);
}

#[test]
fn context_menu_labels_and_intent() {
    let mut r = rt();
    let (x, y) = r.find("entry-0").unwrap();
    r.secondary_down(x, y);
    r.secondary_up(x, y);
    settle(&mut r);
    assert_eq!(r.state.menu, Some(0));
    for label in [
        "Copy ID",
        "Copy",
        "Re-transcribe",
        "Copy logs",
        "Open logs",
        "More info",
    ] {
        assert!(
            r.elements()
                .iter()
                .any(|e| e.label.as_deref() == Some(label) || e.text.as_deref() == Some(label)),
            "missing {label}"
        );
    }
    let e = r
        .elements()
        .into_iter()
        .find(|e| e.label.as_deref() == Some("Copy ID") && e.role == "menuitem")
        .unwrap();
    r.pointer_down(e.rect[0] + 10.0, e.rect[1] + e.rect[3] / 2.0);
    r.pointer_up(e.rect[0] + 10.0, e.rect[1] + e.rect[3] / 2.0);
    settle(&mut r);
    assert!(
        r.state
            .intents
            .last()
            .unwrap()
            .starts_with("intent copy-id")
    );
}

#[test]
fn archive_sources_and_two_thousand_disk_entries() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/history-archive-test");
    std::fs::create_dir_all(&root).unwrap();
    for i in 0..2000 {
        let p = root.join("2026-11-13").join(format!("neutral-{i:04}"));
        std::fs::create_dir_all(&p).unwrap();
        std::fs::write(p.join("audio.wav"), []).unwrap();
        std::fs::write(
            p.join("metadata.json"),
            r#"{"source":"dictation","duration_ms":16000}"#,
        )
        .unwrap();
        std::fs::write(
            p.join("voicelayer-transcript.txt"),
            "Neutral garden example.",
        )
        .unwrap();
    }
    let lists = history::archive::load(&root);
    assert_eq!(lists[0].len(), 2000);
    let mut state = History::new(lists);
    state.limits[0] = 2000;
    let mut r = Runtime::new(state, history::view, (720.0, 720.0), Env::new(true, 2.0));
    settle(&mut r);
    assert!(r.elements().iter().filter(|e| e.role == "listitem").count() < 100);
    // This exact directory is created by this test and contains invented text only.
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn extreme_duration_does_not_panic() {
    let mut state = History::new(history::fixture());
    state.lists[0][0].duration_ms = Some(u64::MAX);
    let mut r = Runtime::new(state, history::view, (720.0, 720.0), Env::new(true, 2.0));
    settle(&mut r);
    assert!(r.find("entry-0").is_some());
}

#[test]
fn r2_archive_edges() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-edges");
    for (id, meta, body, question, audio) in [
        (
            "ask-empty",
            r#"{"source":"voice_ask"}"#,
            "  Response only  ",
            "",
            false,
        ),
        (
            "ask-newline",
            r#"{"source":"voice_ask"}"#,
            "\nAnswer first\n",
            "\nQuestion second\n",
            false,
        ),
        (
            "speech-unknown",
            r#"{"source":"speak","schema_version":1,"id":"speech-unknown"}"#,
            "",
            "",
            false,
        ),
        (
            "speech-error",
            r#"{"source":"speak","schema_version":1,"id":"speech-error","lifecycle":{"summary":{"error_code":"interrupted"}},"audio":{"duration_ms":900000}}"#,
            "",
            "",
            false,
        ),
        (".tmp-x", "{}", "staging", "", true),
        (".hidden", "{}", "hidden", "", true),
        ("broken", "broken", "  Kept recording  ", "", true),
        (
            "no-speech",
            r#"{"not_transcribed_reason":"no-speech"}"#,
            "",
            "",
            true,
        ),
    ] {
        let p = root.join("2026-11-13").join(id);
        std::fs::create_dir_all(&p).unwrap();
        for (name, data) in [
            ("metadata.json", meta),
            ("voicelayer-transcript.txt", body),
            ("agent-transcript.txt", question),
        ] {
            std::fs::write(p.join(name), data).unwrap();
        }
        if audio {
            std::fs::write(p.join("audio.wav"), []).unwrap();
        }
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(root.join("2026-11-13/broken"), root.join("2026-11-13/link"))
        .unwrap();
    let lists = history::archive::load(&root);
    let actual: Vec<Vec<(String, String)>> = lists
        .iter()
        .map(|list| {
            list.iter()
                .map(|e| (e.id.clone(), e.body.clone()))
                .collect()
        })
        .collect();
    assert_eq!(lists[1][0].secondary, "Question second");
    assert_eq!(lists[1][1].secondary, "");
    assert_eq!(lists[2][0].duration_ms, None);
    assert_eq!(lists[2][1].duration_ms, Some(900000));
    assert_eq!(lists[2][1].status, "interrupted");
    for (category, list) in lists.iter().enumerate() {
        let mut state = History::new(lists.clone());
        state.select(category);
        let mut r = Runtime::new(state, history::view, (420.0, 720.0), Env::new(true, 2.0));
        settle(&mut r);
        assert!(!list.is_empty());
        for e in r
            .elements()
            .iter()
            .filter(|e| e.key.as_deref() == Some("row-first"))
        {
            assert!(!e.text.as_deref().unwrap().trim().is_empty());
        }
    }
    std::fs::remove_dir_all(root).unwrap();
    assert_eq!(
        actual,
        vec![
            vec![
                (
                    "no-speech".into(),
                    "Not transcribed: no speech detected".into()
                ),
                ("broken".into(), "Kept recording".into())
            ],
            vec![
                ("ask-newline".into(), "Answer first".into()),
                ("ask-empty".into(), "Response only".into())
            ],
            vec![
                ("speech-unknown".into(), "No text stored".into()),
                ("speech-error".into(), "No text stored".into())
            ],
        ]
    );
}

#[test]
fn r2_badge_waits_for_room() {
    let mut r = rt();
    r.state.pull = 0.2;
    settle(&mut r);
    let es = r.elements();
    let label = es
        .iter()
        .find(|e| e.key.as_deref() == Some("badge-text"))
        .unwrap();
    assert_eq!(label.opacity, 0.0, "label must wait for room");
}

#[test]
fn r2_second_click_collapses() {
    let mut r = rt();
    click(&mut r, "entry-0");
    click(&mut r, "entry-0");
    assert_eq!(r.state.expanded, None);
}

#[test]
fn r2_row_geometry_and_bottom() {
    for width in [420.0, 720.0, 1000.0] {
        let mut r = rt();
        r.viewport = (width, 720.0);
        r.state.lists[0][0].duration_ms = Some(7000);
        r.state.lists[0][1].duration_ms = Some(754000);
        settle(&mut r);
        let es = r.elements();
        let rows: Vec<_> = es
            .iter()
            .filter(|e| e.role == "listitem" && e.visible[3] > 0.0)
            .collect();
        assert!(rows.len() >= 2);
        let mut right = None;
        for card in &rows {
            let within = |key: &str| {
                es.iter()
                    .find(|e| e.path.starts_with(&card.path) && e.key.as_deref() == Some(key))
                    .unwrap()
            };
            for (key, style) in [
                ("row-age", rune::tok::type_::BODY),
                ("row-duration", rune::tok::type_::BODY.features("'tnum' 1")),
            ] {
                let e = within(key);
                assert!(
                    e.rect[2] + 0.5 >= rune::text::advance(e.text.as_deref().unwrap(), style),
                    "timing must fit natural ink"
                );
            }
            let d = within("row-duration");
            let edge = d.rect[0] + d.rect[2];
            if let Some(prev) = right {
                assert!((edge - prev as f32).abs() < 0.5);
            }
            right = Some(edge);
            let block = within("row-text");
            assert!(
                es.iter()
                    .filter(|e| e.path.starts_with(&card.path) && e.path != card.path)
                    .all(|e| e.rect[1] + e.rect[3] <= block.rect[1] + block.rect[3] + 0.5)
            );
            if let Some(second) = es.iter().find(|e| {
                e.path.starts_with(&card.path) && e.key.as_deref() == Some("row-continuation")
            }) {
                assert!(
                    (second.rect[0] + second.rect[2] - (card.rect[0] + card.rect[2] - 12.0)).abs()
                        < 0.5
                );
            }
        }
        for pair in rows.windows(2) {
            assert!(pair[1].rect[1] - pair[0].rect[1] - pair[0].rect[3] >= 6.0);
        }
        let (x, y) = r.find("viewport").unwrap();
        r.wheel(x, y, -100000.0);
        settle(&mut r);
        let es = r.elements();
        let viewport = es
            .iter()
            .find(|e| e.key.as_deref() == Some("viewport"))
            .unwrap();
        for key in ["entry-19", "load-older"] {
            let e = es.iter().find(|e| e.key.as_deref() == Some(key)).unwrap();
            assert!(
                e.rect[1] >= viewport.rect[1]
                    && e.rect[1] + e.rect[3] <= viewport.rect[1] + viewport.rect[3] + 0.5,
                "bottom must fit {key}"
            );
        }
    }
}

#[test]
fn r2_badge_samples() {
    let mut r = rt();
    for i in 0..=20 {
        r.state.pull = i as f32 / 20.0;
        settle(&mut r);
        let es = r.elements();
        assert_eq!(
            es.iter()
                .filter(|e| e.key.as_deref() == Some("settings-handle"))
                .count(),
            1
        );
        let badge = es
            .iter()
            .find(|e| e.key.as_deref() == Some("settings-handle"))
            .unwrap();
        let label = es
            .iter()
            .find(|e| e.key.as_deref() == Some("badge-text"))
            .unwrap();
        assert_eq!(
            badge.label.as_deref(),
            Some(if i == 20 { "armed" } else { "unarmed" })
        );
        assert_eq!(
            label.text.as_deref(),
            Some(if i == 20 {
                "Release for Settings"
            } else {
                "Pull for Settings"
            })
        );
        let natural =
            rune::text::advance(label.text.as_deref().unwrap(), rune::tok::type_::LABEL) + 20.0;
        let expected = ((badge.rect[2] - natural - 24.0) / 30.0).clamp(0.0, 1.0);
        assert!((label.opacity - expected).abs() < 0.01);
        if label.opacity > 0.0 {
            assert!(label.rect[0] >= badge.rect[0] + 12.0);
            assert!(label.rect[0] + label.rect[2] <= badge.rect[0] + badge.rect[2] - 12.0);
            assert!(label.rect[1] >= badge.rect[1]);
            assert!(label.rect[1] + label.rect[3] <= badge.rect[1] + badge.rect[3]);
        }
    }
}

#[test]
fn r2_menu_at_button() {
    let mut r = rt();
    let es = r.elements();
    let button = es
        .iter()
        .find(|e| e.key.as_deref() == Some("row-menu"))
        .unwrap();
    let x = button.rect[0] + button.rect[2] / 2.0;
    let y = button.rect[1] + button.rect[3] / 2.0;
    r.pointer_down(x, y);
    r.pointer_up(x, y);
    settle(&mut r);
    assert_eq!(r.state.menu, Some(0));
    assert!((r.state.menu_anchor[0] - button.rect[0]).abs() < 0.5);
    assert!((r.state.menu_anchor[1] - button.rect[1] - button.rect[3]).abs() < 0.5);
}

#[test]
fn r2_release_has_no_label_in_shrinking_badge() {
    let mut r = rt();
    let (x, y) = r.find("viewport").unwrap();
    r.wheel(x, y, -100000.0);
    settle(&mut r);
    let (x, y) = r.find("pull-zone").unwrap();
    for dy in [50.0, 100.0] {
        r.pointer_down(x, y);
        r.pointer_move(x, y + dy);
        settle(&mut r);
        r.pointer_up(x, y + dy);
        for _ in 0..30 {
            r.frame(1.0 / 60.0);
            let es = r.elements();
            let labels: Vec<_> = es
                .iter()
                .filter(|e| e.key.as_deref() == Some("badge-text"))
                .collect();
            assert_eq!(labels.len(), 1);
            assert_eq!(
                labels[0].opacity, 0.0,
                "release must hide ink before the badge shrinks"
            );
        }
    }
}
