use rune::{Env, Runtime};
use voicebar_rune::settings::{self, Settings, snapshot};
fn rt(page: usize) -> Runtime<Settings> {
    let mut s = Settings::new(snapshot::fixture(), 900., None);
    s.select_page(page);
    let mut r = Runtime::new(s, settings::view, (720., 640.), Env::new(true, 2.));
    settle(&mut r);
    r
}
fn settle(r: &mut Runtime<Settings>) {
    r.invalidate();
    for _ in 0..60 {
        r.frame(1. / 60.);
    }
}
fn x(r: &Runtime<Settings>, name: &str) -> f32 {
    r.elements()
        .iter()
        .find(|e| e.text.as_deref() == Some(name))
        .unwrap()
        .rect[0]
}
#[test]
fn n1_coalesced_release() {
    for (page, dx, name) in [
        (0, -160., "Recognizer"),
        (1, 160., "Controls"),
        (4, 160., "Short"),
    ] {
        let mut r = rt(page);
        let (a, b) = r.find("pager").unwrap();
        r.pointer_down(a, b);
        for i in 1..=5 {
            r.pointer_move(a + dx * i as f32 / 6., b);
            r.frame(1. / 60.);
        }
        let before = x(&r, name);
        r.pointer_move(a + dx, b);
        r.pointer_up(a + dx, b);
        r.frame(0.);
        let mut prev = x(&r, name);
        assert!(
            (prev - before).abs() < 1.,
            "page {page}: {before} -> {prev}"
        );
        for _ in 0..30 {
            r.frame(1. / 60.);
            let now = x(&r, name);
            assert!((now - prev) * dx >= -0.5, "{prev} -> {now}");
            prev = now;
        }
        assert!((prev - 80.).abs() < (before - 80.).abs(), "no progress");
        settle(&mut r);
        assert!((x(&r, name) - 80.).abs() < 0.5);
    }
}
#[test]
fn n3_locked_nodes_disabled() {
    let mut r = rt(1);
    r.state.snapshot.processing_locks = [
        Some("FIXTURE".into()),
        Some("FIXTURE".into()),
        Some("FIXTURE".into()),
    ];
    settle(&mut r);
    fn node<'a>(v: &'a serde_json::Value, k: &str) -> Option<&'a serde_json::Value> {
        if v["key"] == k && v["states"].is_array() {
            return Some(v);
        }
        match v {
            serde_json::Value::Object(o) => o.values().find_map(|v| node(v, k)),
            serde_json::Value::Array(a) => a.iter().find_map(|v| node(v, k)),
            _ => None,
        }
    }
    fn disabled(r: &Runtime<Settings>, k: &str) {
        let t = r.accessibility_json();
        let n = node(&t, k).unwrap_or_else(|| panic!("missing {k}"));
        assert!(
            n["states"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s == "disabled"),
            "{k}: {n}"
        );
    }
    for k in ["toggle-0", "toggle-1", "toggle-2"] {
        disabled(&r, k);
    }
    r.state.select_tab(3);
    r.state.snapshot.speech_locks = std::array::from_fn(|_| Some("FIXTURE".into()));
    r.state.snapshot.threshold_lock = Some("FIXTURE".into());
    r.state.threshold = rune::TextEdit::new("450");
    settle(&mut r);
    for k in [
        "Short-voice-trigger",
        "Long-voice-trigger",
        "Short-rate-minus",
        "Short-rate-plus",
        "Long-rate-minus",
        "Long-rate-plus",
        "threshold-text",
        "apply",
    ] {
        disabled(&r, k);
    }
}
#[test]
fn n4_switches_align_with_mixed_locks() {
    let r = rt(1);
    let es = r.elements();
    let xs: Vec<_> = (0..3)
        .map(|i| {
            es.iter()
                .find(|e| e.key.as_deref() == Some(&format!("toggle-{i}")))
                .unwrap()
                .rect[0]
        })
        .collect();
    assert!(xs.iter().all(|x| (x - xs[0]).abs() < 0.1), "{xs:?}");
}
#[test]
fn n5_rate_minus_align() {
    let r = rt(3);
    assert!(
        (r.find("Short-rate-minus").unwrap().0 - r.find("Long-rate-minus").unwrap().0).abs() < 0.1
    );
}
#[test]
fn n2_history_category_is_instant_after_swipe() {
    let mut r = rt(3);
    let (a, b) = r.find("pager").unwrap();
    r.pointer_down(a, b);
    r.pointer_move(a - 160., b);
    r.frame(0.016);
    r.pointer_up(a - 160., b);
    settle(&mut r);
    let (a, b) = r.find("selector").unwrap();
    r.pointer_down(a + 86., b);
    r.pointer_up(a + 86., b);
    r.frame(0.);
    assert_eq!(r.state.history.category, 2);
    for _ in 0..30 {
        r.frame(1. / 60.);
        let es = r.elements();
        let visible = es
            .iter()
            .filter(|e| {
                e.text.is_some()
                    && e.rect[0] >= 0.
                    && e.rect[0] < 720.
                    && e.rect[1] > 60.
                    && e.rect[1] < 600.
            })
            .count();
        assert!(visible >= 10, "blank category handover: {visible}");
    }
}
#[test]
fn n6_unknown_recognizer_has_no_empty_gap() {
    let mut r = rt(1);
    r.state.snapshot.recognizer = None;
    r.state.snapshot.resident = None;
    settle(&mut r);
    let es = r.elements();
    let v = es
        .iter()
        .find(|e| {
            e.text.as_deref() == Some("Unavailable here")
                && e.path.contains("row-local-recognizer/")
        })
        .unwrap();
    assert!((v.rect[0] + v.rect[2] - 640.).abs() < 0.5);
}
#[test]
fn n7_normalization_defaults_and_wrong_types() {
    let home = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r3-parser");
    let state = home.join(".local/state/voicelayer");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::write(state.join("processing-settings.json"), "{}").unwrap();
    std::fs::write(
        state.join("whisper-performance.json"),
        r#"{"effort":" BALANCED "}"#,
    )
    .unwrap();
    let s = snapshot::read(&home, &Default::default());
    assert_eq!(s.processing, [Some(true), Some(true), Some(false)]);
    assert_eq!(s.configured_effort.as_deref(), Some("balanced"));
    let env = [(
        "QA_VOICE_WHISPER_PERFORMANCE_EFFORT".into(),
        " Fast ".into(),
    )]
    .into();
    let s = snapshot::read(&home, &env);
    assert_eq!(s.configured_effort.as_deref(), Some("fast"));
    assert!(s.effort_lock.is_some());
    std::fs::write(
        state.join("processing-settings.json"),
        r#"{"model_polish":true,"outro_gate":"on","smart_chunks":0}"#,
    )
    .unwrap();
    assert_eq!(
        snapshot::read(&home, &Default::default()).processing,
        [None; 3]
    );
}
#[test]
fn n8_priority_first_is_default_source() {
    let mut r = rt(0);
    r.state.snapshot.default_microphone = Some("stale feed".into());
    settle(&mut r);
    let (a, b) = r.find("make-default-1").unwrap();
    r.pointer_down(a, b);
    r.pointer_up(a, b);
    r.frame(0.);
    assert!(
        r.state
            .intents
            .last()
            .unwrap()
            .contains("from=Built-in microphone to=USB microphone")
    );
}
#[test]
fn n10_outgoing_page_stays_mounted() {
    let mut r = rt(0);
    let (a, b) = r.find("pager").unwrap();
    r.pointer_down(a, b);
    r.pointer_move(a - 160., b);
    r.frame(0.016);
    r.pointer_up(a - 160., b);
    for _ in 0..30 {
        r.frame(1. / 60.);
        assert!(
            r.elements()
                .iter()
                .any(|e| e.text.as_deref() == Some("Controls"))
        );
    }
}
