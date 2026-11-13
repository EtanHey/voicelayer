use rune::{Env, Runtime};
use voicebar_rune::band::*;
const FIXTURE: &str = include_str!("../docs/replays/band.ndjson");
fn runtime(reduced: bool) -> Runtime<Band> {
    let s = Band::new(Replay::parse(FIXTURE).unwrap(), 185., reduced);
    let width = s.width();
    Runtime::new(s, view, (width, HEIGHT), Env::new(true, 2.))
}
fn at(rt: &mut Runtime<Band>, t: f64) {
    rt.update(|s, tx| {
        s.sample(t);
        tx.instant();
    });
    rt.frame(0.);
}
fn rect(rt: &Runtime<Band>, key: &str) -> [f32; 4] {
    rt.elements()
        .iter()
        .find(|e| e.key.as_deref() == Some(key))
        .unwrap()
        .rect
}
#[test]
fn idle_has_no_wings_and_no_external_hits() {
    let mut rt = runtime(false);
    at(&mut rt, 0.);
    assert!(
        !rt.elements()
            .iter()
            .any(|e| e.key.as_deref().is_some_and(|k| k.contains("wing")))
    );
    assert!(rt.hit_regions().is_empty());
}
#[test]
fn recording_opening_timer_and_tight_gap() {
    let mut rt = runtime(false);
    at(&mut rt, 2.9);
    assert_eq!(
        rt.elements()
            .iter()
            .find(|e| e.key.as_deref() == Some("timer"))
            .unwrap()
            .text
            .as_deref(),
        Some("0:00")
    );
    let w = rect(&rt, "waveform");
    let t = rect(&rt, "timer");
    assert!((0. ..=8.).contains(&(t[0] - w[0] - w[2])));
    assert!(rt.find("Stop").is_some());
    assert!(rt.find("Pause").is_some());
    at(&mut rt, 4.1);
    assert_eq!(rt.state.timer(), "0:01");
}
#[test]
fn choreography_travels_monotonically_and_finishes_left() {
    let mut rt = runtime(false);
    let mut previous = f32::INFINITY;
    for i in 0..=72 {
        at(&mut rt, 6. + i as f64 / 60.);
        let r = rect(&rt, "signal");
        let x = r[0] + r[2] / 2.;
        assert!(x <= previous + 0.01, "backwards {previous} -> {x}");
        if previous.is_finite() {
            assert!(previous - x < 40., "jump {previous} -> {x}");
        }
        previous = x;
    }
    assert!(previous < 120.);
    assert!(
        !rt.elements()
            .iter()
            .any(|e| e.key.as_deref() == Some("right-wing"))
    );
    for label in ["Settings", "History"] {
        assert!(
            rt.elements()
                .iter()
                .any(|e| e.label.as_deref() == Some(label) && e.role == "button")
        );
    }
}
#[test]
fn reduce_motion_keeps_every_shared_element_x_stationary() {
    let mut rt = runtime(true);
    at(&mut rt, 6.);
    let baseline = rt.elements();
    for i in 1..=72 {
        at(&mut rt, 6. + i as f64 / 60.);
        for e in rt.elements() {
            if let Some(old) = baseline.iter().find(|b| b.key == e.key && b.key.is_some()) {
                assert_eq!(old.rect[0], e.rect[0], "{:?}", e.key);
            }
        }
    }
}
#[test]
fn all_hit_rectangles_are_inside_drawn_shapes() {
    let mut rt = runtime(false);
    for i in 0..=600 {
        at(&mut rt, i as f64 / 60.);
        for h in rt.hit_regions() {
            assert!(
                rt.elements().iter().any(|e| e.fill.a > 0.
                    && h[0] >= e.rect[0]
                    && h[1] >= e.rect[1]
                    && h[2] <= e.rect[0] + e.rect[2] + 0.01
                    && h[3] <= e.rect[1] + e.rect[3] + 0.01),
                "unpainted hit {h:?}"
            );
        }
    }
}
#[test]
fn replay_trees_are_byte_identical() {
    let (mut a, mut b) = (runtime(false), runtime(false));
    for i in 0..=300 {
        let t = i as f64 / 30.;
        at(&mut a, t);
        at(&mut b, t);
        assert_eq!(format!("{:?}", a.elements()), format!("{:?}", b.elements()));
    }
}
#[test]
fn typed_returns_idle_errors_stay_compact_and_intents_are_inert() {
    let mut rt = runtime(false);
    at(&mut rt, 8.2);
    assert_eq!(rt.state.mode, Mode::Typed);
    at(&mut rt, 9.3);
    assert_eq!(rt.state.mode, Mode::Idle);
    at(&mut rt, 4.);
    let (x, y) = rt.find("Stop").unwrap();
    rt.pointer_down(x, y);
    rt.pointer_up(x, y);
    rt.frame(0.);
    assert_eq!(rt.state.intents, vec!["Stop"]);
    assert_eq!(rt.state.mode, Mode::Recording);
    let replay = Replay::parse("{\"t\":0,\"type\":\"error\",\"message\":\"Try again\"}").unwrap();
    rt.update(|s, tx| {
        s.replay = replay;
        s.sample(0.);
        tx.instant();
    });
    rt.frame(0.);
    assert_eq!(rect(&rt, "left-wing")[3], HEIGHT);
    assert!(rt.find("feedback").is_some());
}
#[test]
fn malformed_replay_is_rejected_and_notchless_is_compact() {
    assert!(Replay::parse("{\"t\":-1,\"type\":\"state\"}").is_err());
    assert!(Replay::parse("{}").is_err());
    let mut s = Band::new(Replay::parse(FIXTURE).unwrap(), 0., false);
    s.sample(0.);
    let mut rt = Runtime::new(s, view, (288., HEIGHT), Env::new(true, 2.));
    rt.frame(0.);
    assert_eq!(rect(&rt, "band")[2], 48.);
}

#[test]
fn scheduled_replay_uses_the_same_clock_as_native_and_headless_tools() {
    let mut rt = runtime(false);
    rt.poll = Some(poll);
    let mut previous = f32::INFINITY;
    rt.frame(0.);
    for _ in 0..310 {
        rt.frame(1. / 30.);
        if rt.state.mode == Mode::Transcribing {
            let r = rect(&rt, "signal");
            let x = r[0] + r[2] / 2.;
            if previous.is_finite() {
                assert!(
                    x <= previous + 0.01 && previous - x <= 40.,
                    "native clock jump {previous} -> {x}"
                );
            }
            previous = x;
        }
    }
    assert!(previous < 120.);
    assert_eq!(rt.state.mode, Mode::Idle);
}
