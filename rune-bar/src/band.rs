//! Replay-only notch band. No IPC, audio, capture or delivery dependencies.
use rune::*;
use serde_json::Value;
use std::time::Duration;

pub const HEIGHT: f32 = 44.;
pub const WING: f32 = 112.;
#[derive(Clone, Debug)]
pub struct Replay(pub Vec<Value>);
impl Replay {
    pub fn parse(source: &str) -> Result<Self, String> {
        let mut events = Vec::new();
        let mut previous = 0.;
        for (i, line) in source.lines().enumerate() {
            let v: Value =
                serde_json::from_str(line).map_err(|e| format!("line {}: {e}", i + 1))?;
            let t = v["t"]
                .as_f64()
                .filter(|t| t.is_finite() && *t >= previous)
                .ok_or_else(|| format!("line {}: invalid or unordered t", i + 1))?;
            if !v["type"].is_string() {
                return Err(format!("line {}: missing type", i + 1));
            }
            previous = t;
            events.push(v);
        }
        Ok(Self(events))
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum Mode {
    Idle,
    Recording,
    Transcribing,
    Typed,
    Error,
}
#[derive(Clone)]
pub struct Band {
    pub replay: Replay,
    pub now: f64,
    pub notch: f32,
    pub reduced: bool,
    pub mode: Mode,
    pub since: f64,
    pub first_level: Option<f64>,
    pub rms: f32,
    pub locked: bool,
    pub paused: bool,
    pub message: String,
    pub queue: u64,
    pub intents: Vec<String>,
}
impl Band {
    pub fn new(replay: Replay, notch: f32, reduced: bool) -> Self {
        Self {
            replay,
            now: 0.,
            notch,
            reduced,
            mode: Mode::Idle,
            since: 0.,
            first_level: None,
            rms: 0.,
            locked: false,
            paused: false,
            message: String::new(),
            queue: 0,
            intents: vec![],
        }
    }
    pub fn width(&self) -> f32 {
        self.notch.max(48.) + 2. * WING + 16.
    }
    pub fn sample(&mut self, now: f64) {
        // Fold from origin: seeking and two independent runs have identical state.
        let replay = self.replay.clone();
        let intents = self.intents.clone();
        *self = Self::new(replay, self.notch, self.reduced);
        self.intents = intents;
        self.now = now;
        for e in self
            .replay
            .0
            .clone()
            .iter()
            .take_while(|e| e["t"].as_f64().unwrap() <= now)
        {
            let t = e["t"].as_f64().unwrap();
            match e["type"].as_str().unwrap_or("") {
                "state" => {
                    let mode = match e["state"].as_str() {
                        Some("recording") => Mode::Recording,
                        Some("transcribing") => Mode::Transcribing,
                        Some("idle") => Mode::Idle,
                        _ => continue,
                    };
                    if mode != self.mode {
                        self.since = t;
                        self.mode = mode;
                    }
                    if self.mode == Mode::Recording {
                        self.locked = e["mode"] == "ptt"; // ptt is the protocol's locked capture mode
                    } else if self.mode == Mode::Idle {
                        self.first_level = None;
                        self.rms = 0.;
                    }
                    if e["recording_jobs"]
                        .as_array()
                        .is_some_and(|jobs| jobs.iter().any(|j| j["phase"] == "processing"))
                        && self.mode == Mode::Idle
                    {
                        self.mode = Mode::Transcribing;
                        self.since = t;
                    }
                }
                "audio_level" if self.mode == Mode::Recording => {
                    self.first_level.get_or_insert(t);
                    self.rms = e["rms"].as_f64().unwrap_or(0.).clamp(0., 1.) as f32;
                }
                "transcription_status" => {
                    if self.mode != Mode::Transcribing {
                        self.mode = Mode::Transcribing;
                        self.since = t;
                    }
                }
                "transcription" if e["partial"] != true => {
                    self.mode = Mode::Typed;
                    self.since = t;
                }
                "error" => {
                    self.mode = Mode::Error;
                    self.since = t;
                    self.message = e["message"]
                        .as_str()
                        .unwrap_or("Try again")
                        .chars()
                        .take(24)
                        .collect();
                }
                "queue" => self.queue = e["depth"].as_u64().unwrap_or(0),
                _ => {}
            }
        }
        if self.mode == Mode::Typed && now - self.since >= 1.2 {
            self.mode = Mode::Idle;
        }
    }
    pub fn timer(&self) -> String {
        let s = self
            .first_level
            .map(|t| (self.now - t).max(0.) as u64)
            .unwrap_or(0);
        format!("{}:{:02}", s / 60, s % 60)
    }
    pub fn progress(&self) -> f32 {
        ((self.now - self.since) as f32 / 1.2).clamp(0., 1.)
    }
}
fn shape(key: &str, x: f32, y: f32, w: f32, h: f32, color: Color) -> El {
    el().key(key)
        .absolute(x, y)
        .size(w, h)
        .radius(8.)
        .fill(color)
}
fn button(key: &'static str, glyph: &str, x: f32) -> El {
    shape(key, x, 8., 28., 28., Color::WHITE.alpha(0.09))
        .role("button")
        .label(key)
        .hit()
        .child(
            text(glyph)
                .font(TextStyle::new(17., 500.))
                .color(Color::WHITE)
                .absolute(6., 3.),
        )
        .on_press(move |s: &mut Band| {
            s.intents.push(key.into());
            println!("{{\"intent\":\"{key}\"}}");
        })
}
pub fn view(s: &Band, cx: &mut Cx<Band>) -> El {
    let reduced = s.reduced || cx.system_reduced_motion();
    let n = s.notch.max(48.);
    let left = 8.;
    let core = left + WING;
    let right = core + n;
    let black = Color::BLACK;
    let blue = Color {
        r: 0.021,
        g: 0.198,
        b: 1.,
        a: 1.,
    };
    let mut root = el().w_full().h_full().instant_changes();
    root = root.child(shape("band", core, 0., n, HEIGHT, black));
    match s.mode {
        Mode::Idle => {}
        Mode::Recording => {
            root = root
                .child(shape("left-wing", left, 0., WING + 8., HEIGHT, black))
                .child(shape(
                    "right-wing",
                    right - 8.,
                    0.,
                    WING + 8.,
                    HEIGHT,
                    black,
                ))
                .child(button("Stop", "■", left + 12.));
            if s.locked {
                root = root.child(button("Pause", "Ⅱ", left + 46.));
            }
            let mut waveform = el()
                .key("waveform")
                .absolute(right + 10., 10.)
                .size(52., 24.);
            for i in 0..9 {
                let h = 3.
                    + s.rms
                        * 19.
                        * (0.35 + 0.65 * (i as f32 * 1.7 + s.now as f32 * 5.).sin().abs());
                waveform = waveform.child(
                    shape(
                        &format!("wave-{i}"),
                        i as f32 * 6.,
                        12. - h / 2.,
                        3.,
                        h,
                        Color {
                            r: 1.,
                            g: 0.051,
                            b: 0.095,
                            a: 1.,
                        },
                    )
                    .matched(format!("signal-0-{i}")),
                );
            }
            root = root.child(waveform).child(
                text(s.timer())
                    .key("timer")
                    .role("label")
                    .label(s.timer())
                    .absolute(right + 68., 13.)
                    .font(TextStyle::new(12., 550.))
                    .color(Color::WHITE),
            );
        }
        Mode::Transcribing => {
            let p = s.progress();
            // Critically damped Rune spring, explicitly sampled on the replay clock.
            let travel = tok::motion::CALM.with_duration(0.8)
                .sample(0., 0., 1., ((p - 0.18).max(0.) * 1.2).min(1.))
                .0;
            let travel = if p >= 1. { 1. } else { travel.clamp(0., 1.) };
            let shrink = if reduced { 0. } else { 1. - travel };
            root = root.child(shape("left-wing", left, 0., WING + 8., HEIGHT, black));
            if shrink > 0.001 {
                root = root.child(shape(
                    "right-wing",
                    right - 8.,
                    0.,
                    (WING + 8.) * shrink,
                    HEIGHT,
                    black,
                ));
            }
            root = root
                .child(button("Settings", "⚙", left + 44.))
                .child(button("History", "◴", left + 76.));
            let start = right + 36.;
            let end = left + 24.;
            // Fixed endpoints for Reduce Motion: two stationary groups cross-fade.
            for side in 0..if reduced { 2 } else { 1 } {
                let x = if reduced {
                    if side == 0 { start } else { end }
                } else {
                    start + (end - start) * travel
                };
                let alpha = if reduced {
                    if side == 0 { 1. - p } else { p }
                } else {
                    1.
                };
                let mut dots = el()
                    .key(if side == 0 {
                        "signal"
                    } else {
                        "reduced-spinner"
                    })
                    .absolute(x - 26., 8.)
                    .size(52., 28.)
                    .opacity(alpha);
                for i in 0..9 {
                    let a = i as f32 * std::f32::consts::TAU / 9.;
                    let spin = if reduced {
                        1.
                    } else {
                        ((p - 0.8) * 5.).clamp(0., 1.)
                    };
                    let dx = (i as f32 * 6. - 26.) * (1. - spin) + a.cos() * 9. * spin;
                    let dy = a.sin() * 9. * spin;
                    let h = 3. + (1. - (p / 0.18).min(1.)) * s.rms * 18.;
                    dots = dots.child(
                        shape(
                            &format!("dot-{side}-{i}"),
                            26. + dx,
                            14. + dy - h / 2.,
                            3.,
                            h,
                            blue,
                        )
                        .matched(format!("signal-{side}-{i}"))
                        .opacity(if spin > 0.9 {
                            0.3 + 0.7 * ((i as f32 / 9. + s.now as f32) % 1.)
                        } else {
                            1.
                        }),
                    );
                }
                root = root.child(dots);
            }
        }
        Mode::Typed | Mode::Error => {
            root = root
                .child(shape("left-wing", left, 0., WING + 8., HEIGHT, black))
                .child(
                    text(if s.mode == Mode::Typed {
                        "✓ Typed"
                    } else {
                        &s.message
                    })
                    .key("feedback")
                    .absolute(left + 12., 14.)
                    .font(TextStyle::new(11., 500.))
                    .color(Color::WHITE),
                );
        }
    }
    root.child(shape("notch-occlusion", core, 0., n, HEIGHT, black))
}
pub fn poll(s: &mut Band, clock: f64, tx: &mut Tx) -> bool {
    let previous = s.now;
    s.sample(clock);
    let future = s.replay.0.iter().find_map(|e| {
        let t = e["t"].as_f64()?;
        (t > clock).then_some(t)
    });
    let active = matches!(s.mode, Mode::Recording | Mode::Transcribing | Mode::Typed);
    if active {
        tx.wake_after(Duration::from_secs_f64(1. / 30.));
    } else if let Some(t) = future {
        tx.wake_after(Duration::from_secs_f64((t - clock).max(0.001)));
    }
    clock != previous && (active || future.is_some() || previous < s.since + 1.3)
}
