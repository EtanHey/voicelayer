use rune::{Env, Runtime};
use voicebar_rune::*;
#[test]
fn malformed_entries_preserve_valid_terms() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../.build.noindex/r2-malformed.json");
    std::fs::write(&path,r#"{"entries":[{"canonical":"Alpha","variants":["a",8," "]},{"canonical":"Beta","variants":null},42,{"canonical":" "}]}"#).unwrap();
    let entries = read_entries(&path);
    std::fs::remove_file(path).unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].variants, vec!["a"]);
    let mut rt = Runtime::new(
        Dictionary::new(entries, 900., None),
        view,
        (WIDTH, DEFAULT_HEIGHT),
        Env::new(true, 2.),
    );
    rt.frame(0.);
    assert!(
        rt.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Your terms (2)"))
    );
}
#[test]
fn toolbar_grouping_density_and_handle() {
    let mut rt = Runtime::new(
        Dictionary::new(fixture(), 900., None),
        view,
        (WIDTH, 900.),
        Env::new(true, 2.),
    );
    rt.frame(0.);
    let nodes = rt.elements();
    let rect = |key: &str| {
        nodes
            .iter()
            .find(|e| e.key.as_deref() == Some(key))
            .unwrap()
            .rect
    };
    let a = rect("search");
    let b = rect("add");
    for (x, y) in [
        (a[1], b[1]),
        (a[3], b[3]),
        (a[1] + a[3] / 2., b[1] + b[3] / 2.),
    ] {
        assert!((x - y).abs() <= 0.5);
    }
    let grip = rect("bottom-edge");
    let mark = rect("resize-mark");
    assert!((grip[0] + grip[2] / 2.0 - mark[0] - mark[2] / 2.0).abs() <= 0.5);
    assert!(nodes.iter().any(|e| e.key.as_deref() == Some("scroll-bar")));
    assert!(nodes.iter().any(|e| e.key.as_deref() == Some("thumb")));
    let plain = rect("term-0-0");
    let variant = rect("term-0-1");
    assert!((44. ..=48.).contains(&plain[3]));
    assert!(variant[3] > plain[3]);
    let last = rect("term-0-3");
    let header = rect("group-1");
    let first = rect("term-1-0");
    assert!(header[1] - last[1] - last[3] >= 2. * (first[1] - header[1] - header[3]));
    assert!(
        nodes
            .iter()
            .any(|e| e.key.as_deref() == Some("resize-mark"))
    );
    assert!(
        nodes
            .iter()
            .any(|e| e.key.as_deref() == Some("icon") && e.path.contains("/add/"))
    );
}
#[test]
fn unicode_fold_search() {
    let mut s = Dictionary::new(
        vec![Entry {
            canonical: "Straße".into(),
            variants: vec![],
        }],
        900.,
        None,
    );
    s.search.text = "STRASSE".into();
    assert_eq!(s.matches(0), vec![0]);
}
#[test]
fn geometry_waits_for_quiet_then_relaunches() {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.build.noindex/r2-debounce.json");
    let mut s = Dictionary::new(vec![], 900., Some(path.clone()));
    for frame in 0..60 {
        let now = frame as f64 / 60.;
        s.observe_resize(650. + frame as f32, now);
        s.flush_resize(now);
        assert!(!path.exists());
    }
    s.flush_resize(1.2);
    assert!(!path.exists());
    s.flush_resize(1.3);
    assert_eq!(
        Dictionary::new(vec![], 900., Some(path.clone())).height,
        709.
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn fixture_pixel_contracts_and_virtual_band_comparison() {
    let result = std::process::Command::new("python3")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/pictures.py"))
        .args([
            env!("CARGO_BIN_EXE_voicebar-rune"),
            env!("CARGO_BIN_EXE_trailing-band"),
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}
