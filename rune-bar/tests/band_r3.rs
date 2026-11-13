use rune::{Env, Runtime};
use voicebar_rune::band::*;
fn runtime(source: &str) -> Runtime<Band> {
    let s = Band::new(Replay::parse(source).unwrap(), 185., false);
    Runtime::new(s, view, (425., HEIGHT), Env::new(true, 2.))
}
fn at(r: &mut Runtime<Band>, t: f64) {
    r.update(|s, tx| {
        s.sample(t);
        tx.instant();
    });
    r.frame(0.);
}
#[test]
fn brightest_head_orbits_quarter_turn() {
    let mut r = runtime(include_str!("../docs/replays/band.ndjson"));
    let mut angle = |t| {
        at(&mut r, t);
        let es = r.elements();
        let d = es
            .iter()
            .filter(|e| e.key.as_deref().is_some_and(|k| k.starts_with("dot-")))
            .max_by(|a, b| a.opacity.total_cmp(&b.opacity))
            .unwrap();
        (d.rect[1] + 1.5 - 22.)
            .atan2(d.rect[0] + 1.5 - 102.)
            .to_degrees()
    };
    let a = angle(6.45);
    let b = angle(6.65);
    let delta = (b - a).rem_euclid(360.);
    assert!((delta - 90.).abs() <= 20., "head moved {delta} degrees");
}
#[test]
fn both_idle_exits_fade_without_removals_above_half_opacity() {
    for source in [
        include_str!("../docs/replays/band-cancel.ndjson"),
        include_str!("../docs/replays/band-cancel-transcribing.ndjson"),
    ] {
        let mut r = runtime(source);
        let exit = r.state.replay.0.last().unwrap()["t"].as_f64().unwrap();
        r.state.sample(exit + 0.05);
        assert!(
            r.state.input_active(),
            "input disabled before exit completes"
        );
        let mut tx = rune::Tx::default();
        assert!(poll(&mut r.state, exit + 0.151, &mut tx));
        assert!(!r.state.input_active(), "input still armed after exit");

        let mut previous: Vec<rune::ElementInfo> = vec![];
        for i in 0..=90 {
            at(&mut r, 5.9 + i as f64 / 60.);
            let es = r.elements();
            for old in previous
                .iter()
                .filter(|e| e.opacity > 0.5 && e.key.is_some())
            {
                assert!(
                    es.iter().any(|e| e.key == old.key),
                    "removed {:?} at {i}",
                    old.key
                );
            }
            previous = es;
        }
        assert_eq!(r.state.mode, Mode::Idle);
        assert!(
            r.elements()
                .iter()
                .all(|e| e.key.as_deref() != Some("band-surface"))
        );
    }
}
#[test]
fn recoverable_error_keeps_take_and_transcribes_normally() {
    let mut r = runtime(
        r#"{"t":2,"type":"state","state":"recording","mode":"ptt"}
{"t":5,"type":"error","message":"Microphone note","recoverable":true,"show_during_bar_recording":true}
{"t":6,"type":"state","state":"transcribing"}"#,
    );
    r.poll = Some(poll);
    r.frame(0.);
    for _ in 0..306 {
        r.frame(1. / 60.);
    }
    assert!(
        r.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Microphone note")),
        "scheduled replay failed to redraw recoverable note"
    );
    r.poll = None;
    at(&mut r, 5.1);
    assert_eq!(r.state.mode, Mode::Recording);
    assert_eq!(r.state.since, 2.);
    assert!(
        r.elements()
            .iter()
            .any(|e| e.text.as_deref() == Some("Microphone note"))
    );
    at(&mut r, 6.45);
    assert_eq!(r.state.mode, Mode::Transcribing);
    assert_eq!(r.state.transcribing_since, Some(6.));
}
