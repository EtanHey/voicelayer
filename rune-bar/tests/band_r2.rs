use rune::{Env, Runtime};
use voicebar_rune::band::*;
fn band(events: &str) -> Band {
    Band::new(Replay::parse(events).unwrap(), 185., false)
}
fn rt(reduced: bool, fast: bool) -> Runtime<Band> {
    let source = include_str!("../docs/replays/band.ndjson");
    let source = if fast {
        source
            .replace("\"t\":8,", "\"t\":6.3,")
            .replace("\"t\":10,", "\"t\":6.31,")
            .replace("\"t\":8.01,", "\"t\":6.31,")
    } else {
        source.into()
    };
    let mut s = band(&source);
    s.reduced = reduced;
    let w = s.width();
    Runtime::new(s, view, (w, HEIGHT), Env::new(true, 2.))
}
fn at(r: &mut Runtime<Band>, t: f64) {
    r.update(|s, tx| {
        s.sample(t);
        tx.instant();
    });
    r.frame(0.);
}
fn inside(a: [f32; 4], b: [f32; 4]) -> bool {
    a[0] >= b[0] - 0.01
        && a[1] >= b[1] - 0.01
        && a[0] + a[2] <= b[0] + b[2] + 0.01
        && a[1] + a[3] <= b[1] + b[3] + 0.01
}
#[test]
fn real_order_preserves_typed_and_error_expires() {
    let mut s = band(
        "{\"t\":0,\"type\":\"transcription\"}\n{\"t\":0.01,\"type\":\"state\",\"state\":\"idle\",\"source\":\"recording\"}",
    );
    s.sample(1.19);
    assert_eq!(s.mode, Mode::Typed);
    s.sample(1.21);
    assert_eq!(s.mode, Mode::Idle);
    let mut s = band("{\"t\":0,\"type\":\"error\"}");
    s.sample(1.21);
    assert_eq!(s.mode, Mode::Idle);
}
#[test]
fn unrelated_events_and_new_take_timer() {
    for mode in ["recording", "transcribing"] {
        let mut s = band(&format!(
            "{{\"t\":0,\"type\":\"state\",\"state\":\"{mode}\"}}\n{{\"t\":1,\"type\":\"state\",\"state\":\"idle\",\"source\":\"playback\"}}\n{{\"t\":2,\"type\":\"error\",\"source\":\"seek\"}}\n{{\"t\":3,\"type\":\"error\",\"source\":\"playback\"}}"
        ));
        s.sample(3.);
        assert_eq!(
            s.mode,
            if mode == "recording" {
                Mode::Recording
            } else {
                Mode::Transcribing
            }
        );
    }
    let mut s = band(
        "{\"t\":0,\"type\":\"state\",\"state\":\"recording\"}\n{\"t\":1,\"type\":\"audio_level\",\"rms\":0.8}\n{\"t\":2,\"type\":\"state\",\"state\":\"transcribing\"}\n{\"t\":3,\"type\":\"state\",\"state\":\"recording\"}",
    );
    s.sample(3.1);
    assert_eq!(s.timer(), "0:00");
    assert_eq!(s.rms, 0.);
}
#[test]
fn dots_controls_opacity_ring_and_containment() {
    for reduced in [false, true] {
        for fast in [false, true] {
            let mut r = rt(reduced, fast);
            let mut previous: Vec<rune::ElementInfo> = vec![];
            for i in 0..=100 {
                at(&mut r, 5.9 + i as f64 / 60.);
                let es = r.elements();
                // Missing keyed paint is opacity zero, including removals.
                for key in es.iter().chain(&previous).filter_map(|e| e.key.as_ref()) {
                    let visible = |items: &[rune::ElementInfo]| {
                        items
                            .iter()
                            .find(|e| e.key.as_ref() == Some(key))
                            .map(|e| {
                                if e.fill.a > 0. || e.text.is_some() {
                                    e.opacity
                                } else {
                                    0.
                                }
                            })
                            .unwrap_or(0.)
                    };
                    assert!(
                        (visible(&es) - visible(&previous)).abs() <= 0.5 || previous.is_empty(),
                        "opacity {key} at {i}"
                    );
                }
                for e in &es {
                    if let Some(old) = previous.iter().find(|p| p.key == e.key && e.key.is_some()) {
                        if reduced {
                            assert_eq!(e.rect[0], old.rect[0], "moving {:?}", e.key);
                        }
                    }
                }
                for d in es.iter().filter(|e| {
                    e.key.as_deref().is_some_and(|k| k.starts_with("dot-")) && e.opacity > 0.01
                }) {
                    assert!(
                        es.iter().any(|e| matches!(
                            e.key.as_deref(),
                            Some(
                                "band"
                                    | "band-surface"
                                    | "recording-surface"
                                    | "left-wing"
                                    | "right-wing"
                                    | "notch-occlusion"
                            )
                        ) && e.fill.a == 1.
                            && e.opacity + 0.001 >= d.opacity
                            && inside(d.rect, e.rect)),
                        "floating {:?} at {i}",
                        d.rect
                    );
                    for c in es.iter().filter(|e| {
                        matches!(
                            e.label.as_deref(),
                            Some("Stop" | "Pause" | "Settings" | "History")
                        ) && e.opacity > 0.01
                    }) {
                        let a = d.rect;
                        let b = c.rect;
                        assert!(
                            a[0] + a[2] <= b[0]
                                || b[0] + b[2] <= a[0]
                                || a[1] + a[3] <= b[1]
                                || b[1] + b[3] <= a[1],
                            "dot/control at {i}: {:?}",
                            c.key
                        );
                    }
                }
                if !fast && i == 33 && !reduced {
                    let sig = es
                        .iter()
                        .find(|e| e.key.as_deref() == Some("signal"))
                        .unwrap();
                    let center = [sig.rect[0] + 26., 22.];
                    for d in es
                        .iter()
                        .filter(|e| e.key.as_deref().is_some_and(|k| k.starts_with("dot-")))
                    {
                        let radius = ((d.rect[0] + 1.5 - center[0]).powi(2)
                            + (d.rect[1] + 1.5 - center[1]).powi(2))
                        .sqrt();
                        assert!((radius - 9.).abs() < 0.5, "radius {radius}");
                    }
                    assert!(!es.iter().any(|e| e.key.as_deref() == Some("right-wing")));
                }
                if !reduced {
                    if let Some(sig) = es.iter().find(|e| e.key.as_deref() == Some("signal")) {
                        if sig.rect[0] + 26. >= 120. {
                            assert!(
                                es.iter()
                                    .filter(|e| matches!(
                                        e.label.as_deref(),
                                        Some("Settings" | "History")
                                    ))
                                    .all(|e| e.opacity <= 0.01)
                            );
                        }
                    }
                }
                previous = es;
            }
        }
    }
}
#[test]
fn recording_wing_fits_controls() {
    for mode in ["ptt", "vad"] {
        let s = band(&format!(
            "{{\"t\":0,\"type\":\"state\",\"state\":\"recording\",\"mode\":\"{mode}\"}}"
        ));
        let mut r = Runtime::new(s, view, (425., HEIGHT), Env::new(true, 2.));
        at(&mut r, 0.);
        let es = r.elements();
        let wing = es
            .iter()
            .find(|e| e.key.as_deref() == Some("left-wing"))
            .unwrap();
        let min = es
            .iter()
            .filter(|e| e.role == "button")
            .map(|e| e.rect[0])
            .fold(f32::INFINITY, f32::min);
        let max = es
            .iter()
            .filter(|e| e.role == "button")
            .map(|e| e.rect[0] + e.rect[2])
            .fold(0., f32::max);
        assert!(wing.rect[2] - (max - min) <= 16.);
    }
}
#[test]
fn idle_safe_top_and_quiet_poll() {
    let mut r = rt(false, false);
    at(&mut r, 0.);
    let b = r
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("band"))
        .unwrap();
    assert_eq!(b.rect, [120., 0., 185., 32.]);
    let mut s = band(include_str!("../docs/replays/band.ndjson"));
    s.sample(2.1);
    let mut tx = rune::Tx::default();
    assert!(!poll(&mut s, 2.2, &mut tx));
    r.poll = Some(poll);
    r.frame(11.);
    r.frame(0.);
    assert_eq!(r.state.mode, Mode::Idle);
    assert!(r.wake_deadline().is_none(), "idle still scheduled");
}
#[test]
fn completed_ring_rotates() {
    let mut r = rt(false, false);
    at(&mut r, 6.45);
    let a = r
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("dot-0-0"))
        .unwrap();
    at(&mut r, 6.55);
    let b = r
        .elements()
        .into_iter()
        .find(|e| e.key.as_deref() == Some("dot-0-0"))
        .unwrap();
    assert_ne!(a.rect, b.rect);
}
#[test]
fn malformed_cli_exits_two() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_band"))
        .args(["--replay", "Cargo.toml", "--snap", "unused.png"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("line 1"));
    assert!(!error.contains("panicked"));
}
#[test]
fn visible_dot_steps_are_bounded_at_film_and_tree_rates() {
    for hz in [30., 60.] {
        let mut r = rt(false, false);
        let mut previous = vec![];
        for i in 0..=(hz as usize) {
            at(&mut r, 6. + i as f64 / hz);
            let es = r.elements();
            for e in es
                .iter()
                .filter(|e| e.key.as_deref().is_some_and(|k| k.starts_with("dot-")))
            {
                if let Some(old) = previous
                    .iter()
                    .find(|p: &&rune::ElementInfo| p.key == e.key)
                {
                    let hidden = e.rect[0] >= 120. && e.rect[0] + e.rect[2] <= 305.;
                    if !hidden {
                        assert!(
                            (e.rect[0] - old.rect[0]).abs() <= 40.,
                            "visible dot jumped at {hz}Hz frame {i}"
                        );
                    }
                }
            }
            previous = es;
        }
    }
}
