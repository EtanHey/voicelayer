//! Pure band state and view. Socket transport never records, plays or delivers input.
use rune::*;
use serde_json::Value;

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
    pub live: bool,
    pub skipped_lines: u64,
    logical_mode: Mode,
    pub notch: f32,
    pub safe_top: f32,
    pub transcribing_since: Option<f64>,
    pub exit_from: Option<Box<Band>>,
    pub recoverable_since: Option<f64>,
    pub overlay: Option<OverlayHandle<Band>>,
    pub keep_regions: bool,
    pub reduced: bool,
    pub system_motion: bool,
    pub content_alpha: f32,
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
            live: false,
            skipped_lines: 0,
            logical_mode: Mode::Idle,
            notch,
            safe_top: 32.,
            transcribing_since: None,
            exit_from: None,
            recoverable_since: None,
            overlay: None,
            keep_regions: false,
            reduced,
            system_motion: false,
            content_alpha: 1.,
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
        let events = self.replay.clone();
        let (overlay, intents) = (self.overlay.clone(), std::mem::take(&mut self.intents));
        let (safe_top, keep_regions, system_motion) =
            (self.safe_top, self.keep_regions, self.system_motion);
        *self = Self::new(events.clone(), self.notch, self.reduced);
        self.overlay = overlay;
        self.intents = intents;
        self.safe_top = safe_top;
        self.keep_regions = keep_regions;
        self.system_motion = system_motion;
        for e in events
            .0
            .iter()
            .take_while(|e| e["t"].as_f64().unwrap() <= now)
        {
            self.apply(e, e["t"].as_f64().unwrap());
        }
        self.advance(now);
    }
    // A bounded snapshot: never clones a replay log, previous exit, or intent history.
    fn snapshot(&self) -> Self {
        let mut s = Self::new(Replay(vec![]), self.notch, self.reduced);
        s.now = self.now;
        s.safe_top = self.safe_top;
        s.mode = self.mode.clone();
        s.logical_mode = self.logical_mode.clone();
        s.since = self.since;
        s.first_level = self.first_level;
        s.rms = self.rms;
        s.locked = self.locked;
        s.paused = self.paused;
        s.message = self.message.clone();
        s.transcribing_since = self.transcribing_since;
        s.recoverable_since = self.recoverable_since;
        s.queue = self.queue;
        s
    }
    /// Incremental fold, constant retained state; t is local monotonic receive time.
    pub fn apply(&mut self, e: &Value, t: f64) {
        self.mode = self.logical_mode.clone();
        self.now = t;
        match e["type"].as_str().unwrap_or("") {
            "state" => {
                let mode = match e["state"].as_str() {
                    Some("recording") => Mode::Recording,
                    Some("transcribing") => Mode::Transcribing,
                    Some("idle") => Mode::Idle,
                    _ => return,
                };
                if mode == Mode::Idle
                    && ((e["source"] == "playback"
                        && matches!(self.mode, Mode::Recording | Mode::Transcribing))
                        || matches!(self.mode, Mode::Typed | Mode::Error))
                {
                    self.logical_mode = self.mode.clone();
                    return;
                }
                if mode != self.mode {
                    if mode == Mode::Idle
                        && matches!(self.mode, Mode::Recording | Mode::Transcribing)
                        && !e["recording_jobs"]
                            .as_array()
                            .is_some_and(|jobs| jobs.iter().any(|j| j["phase"] == "processing"))
                    {
                        let mut outgoing = self.snapshot();
                        outgoing.now = t;
                        outgoing.exit_from = None;
                        self.exit_from = Some(Box::new(outgoing));
                    } else {
                        self.exit_from = None;
                    }
                    if mode == Mode::Recording {
                        self.recoverable_since = None;
                        self.first_level = None;
                        self.rms = 0.;
                        self.transcribing_since = None;
                    }
                    if mode == Mode::Transcribing {
                        self.transcribing_since = Some(t);
                    }
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
                    self.transcribing_since = Some(t);
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
                    self.transcribing_since = Some(t);
                    self.since = t;
                }
            }
            "transcription" if e["partial"] != true => {
                self.mode = Mode::Typed;
                self.since = t;
            }
            "error" => {
                if e["source"] == "playback" || e["source"] == "seek" {
                    self.logical_mode = self.mode.clone();
                    return;
                }
                if e["recoverable"] == true
                    && matches!(self.mode, Mode::Recording | Mode::Transcribing)
                {
                    self.recoverable_since = Some(t);
                    self.message = e["message"]
                        .as_str()
                        .unwrap_or("Try again")
                        .chars()
                        .take(24)
                        .collect();
                    self.logical_mode = self.mode.clone();
                    return;
                }
                self.transcribing_since = None;
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
        self.logical_mode = self.mode.clone();
    }
    pub fn receive(&mut self, message: crate::socket::Message, t: f64) {
        match message {
            crate::socket::Message::Event(e) => self.apply(&e, t),
            crate::socket::Message::Skipped => self.skipped_lines += 1,
            crate::socket::Message::Disconnected => self.disconnect(t),
            crate::socket::Message::Retrying(_) => {}
        }
        if !self.keep_regions {
            if let Some(handle) = &self.overlay {
                handle.set_input(if self.input_active() {
                    OverlayInput::Regions
                } else {
                    OverlayInput::None
                });
            }
        }
    }
    pub fn disconnect(&mut self, t: f64) {
        let mut outgoing = self.snapshot();
        outgoing.now = t;
        self.exit_from = (self.mode != Mode::Idle).then(|| Box::new(outgoing));
        self.mode = Mode::Idle;
        self.logical_mode = Mode::Idle;
        self.since = t;
        self.first_level = None;
        self.rms = 0.;
        self.recoverable_since = None;
        self.advance(t);
    }
    pub fn advance(&mut self, now: f64) {
        self.now = now;
        self.mode = self.logical_mode.clone();
        if matches!(self.mode, Mode::Typed | Mode::Error) && now - self.since >= 1.2 {
            self.mode = Mode::Idle;
        }
    }
    pub fn input_active(&self) -> bool {
        self.mode != Mode::Idle || self.exit_from.is_some() && self.now - self.since < 0.15
    }
    pub fn timer(&self) -> String {
        let s = self
            .first_level
            .map(|t| (self.now - t).max(0.) as u64)
            .unwrap_or(0);
        format!("{}:{:02}", s / 60, s % 60)
    }
    pub fn progress(&self) -> f32 {
        ((self.now - self.since) as f32 / 0.45).clamp(0., 1.)
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
// Analytically sampled strong ease-in-out, cubic-bezier(0.77,0,0.175,1).
fn travel_curve(p: f32) -> f32 {
    let x = p.clamp(0., 1.);
    let (mut lo, mut hi) = (0., 1.);
    for _ in 0..20 {
        let t = (lo + hi) / 2.;
        let u = 1. - t;
        if 3. * u * u * t * 0.77 + 3. * u * t * t * 0.175 + t * t * t < x {
            lo = t;
        } else {
            hi = t;
        }
    }
    let t = (lo + hi) / 2.;
    3. * (1. - t) * t * t + t * t * t
}
fn ease(p: f32) -> f32 {
    let p = p.clamp(0., 1.);
    1. - (1. - p).powi(3)
}
fn red() -> Color {
    Color {
        r: 1.,
        g: 0.051,
        b: 0.095,
        a: 1.,
    }
}
fn blue() -> Color {
    // sRGB #3355FF converted to linear light.
    Color {
        r: 0.033104766,
        g: 0.09084171,
        b: 1.,
        a: 1.,
    }
}
fn controls(root: El, s: &Band, core: f32, alpha: f32) -> El {
    let root =
        root.child(button("Stop", "■", core - if s.locked { 64. } else { 32. }).opacity(alpha));
    if s.locked {
        root.child(button("Pause", "Ⅱ", core - 32.).opacity(alpha))
    } else {
        root
    }
}
fn timer(s: &Band, right: f32, alpha: f32) -> El {
    text(s.timer())
        .key("timer")
        .role("label")
        .label(s.timer())
        .absolute(right + 68., 13.)
        .font(TextStyle::new(12., 550.))
        .color(Color::WHITE)
        .opacity(alpha)
}
pub fn view(s: &Band, _cx: &mut Cx<Band>) -> El {
    if s.system_motion && _cx.system_reduced_motion() && !s.reduced {
        let mut reduced = s.clone();
        reduced.reduced = true;
        return view(&reduced, _cx);
    }
    // Headless reduced motion is explicit replay input.
    let n = s.notch.max(48.);
    let core = 120.;
    let right = core + n;
    let mut root = el().w_full().h_full().instant_changes().child(shape(
        "band",
        core,
        0.,
        n,
        s.safe_top.min(HEIGHT),
        Color::BLACK,
    ));
    if s.mode == Mode::Idle {
        if let Some(old) = &s.exit_from {
            let alpha = 1. - ease(((s.now - s.since) / 0.15) as f32);
            if alpha > 0.001 {
                return root.child(el().opacity(alpha).child(view(old, _cx)));
            }
        }
        return root;
    }
    if s.mode == Mode::Typed || s.mode == Mode::Error {
        let age = (s.now - s.since) as f32;
        let enter = ease(
            (s.now
                - s.transcribing_since
                    .map(|t| (t + 0.45).max(s.since) + 0.12)
                    .unwrap_or(s.since)) as f32
                / 0.12,
        );
        let exit = ease((1.2 - age) / 0.15);
        // Finish the signal under the retained opaque geometry, then fade it out.
        if let Some(start) = s.transcribing_since {
            let finish = (start + 0.45).max(s.since);
            if s.now < finish + 0.12 {
                let mut old = s.clone();
                old.mode = Mode::Transcribing;
                old.since = start;
                old.content_alpha = 1. - ease(((s.now - finish) / 0.12) as f32);
                return view(&old, _cx);
            }
        }
        return root
            .child(shape("band-surface", 8., 0., right - 8., HEIGHT, Color::BLACK).opacity(exit))
            .child(
                shape(
                    "left-wing",
                    if s.reduced {
                        core - if s.locked { 72. } else { 40. }
                    } else {
                        8.
                    },
                    0.,
                    if s.reduced {
                        if s.locked { 72. } else { 40. }
                    } else {
                        core - 8.
                    },
                    HEIGHT,
                    Color::TRANSPARENT,
                )
                .radius(0.)
                .opacity(exit),
            )
            .child(feedback(s, core, enter * exit));
    }
    let age = (s.now - s.since).max(0.) as f32;
    let trans = s.mode == Mode::Transcribing;
    let control_alpha = (if trans { 1. - ease(age / 0.1) } else { 1. }) * s.content_alpha;
    let wing_start = core - if s.locked { 72. } else { 40. };
    let left = if trans {
        if s.reduced {
            wing_start
        } else {
            wing_start + (8. - wing_start) * ease(age / 0.1)
        }
    } else {
        wing_start
    };
    let start = right + 35.5;
    let end = core - 18.;
    let x = if !trans || age <= 0.1 {
        start
    } else if age < 0.18 {
        start + (right - 26. - start) * ((age - 0.1) / 0.08).clamp(0., 1.)
    } else if age < 0.2 {
        right - 26. + (core + 26. - (right - 26.)) * travel_curve((age - 0.18) / 0.02)
    } else {
        core + 26. + (end - core - 26.) * ((age - 0.2) / 0.08).clamp(0., 1.)
    };
    let right_width = if !trans {
        112.
    } else if s.reduced {
        0.
    } else {
        // Never shrink past the visible signal; its fast middle is occluded by the notch.
        (112. * (1. - ease((age - 0.1) / 0.22))).max((x + 28. - right).clamp(0., 112.))
    };
    root = root.child(
        shape(
            "band-surface",
            if s.reduced { 8. } else { left },
            0.,
            right + if s.reduced { 0. } else { right_width } - if s.reduced { 8. } else { left },
            HEIGHT,
            Color::BLACK,
        )
        .opacity(if s.reduced {
            if trans { ease(age / 0.15) } else { 0. }
        } else {
            1.
        }),
    );
    if s.reduced && (!trans || age < 0.3) {
        root = root.child(
            shape(
                "recording-surface",
                wing_start,
                0.,
                right - wing_start,
                HEIGHT,
                Color::BLACK,
            )
            .opacity(if trans {
                1. - ease((age - 0.15) / 0.15)
            } else {
                1.
            }),
        );
    }
    root = root.child(
        shape(
            "left-wing",
            left,
            0.,
            core - left,
            HEIGHT,
            Color::TRANSPARENT,
        )
        .radius(0.),
    );
    if s.reduced && (!trans || age < 0.3) {
        // Outgoing bars fade before the stationary opaque wing starts its own fade.
        root = root.child(
            shape("right-wing", right - 8., 0., 120., HEIGHT, Color::BLACK).opacity(if trans {
                1. - ease((age - 0.15) / 0.15)
            } else {
                1.
            }),
        );
    }
    if !s.reduced && right_width > 0.01 {
        root = root.child(
            shape(
                "right-wing",
                right - 8.,
                0.,
                right_width + 8.,
                HEIGHT,
                Color::TRANSPARENT,
            )
            .radius(0.)
            .opacity((right_width / 112.).clamp(0., 1.)),
        );
    }
    if !trans || control_alpha > 0.001 {
        root = controls(root, s, core, control_alpha).child(timer(s, right, control_alpha));
    }
    if !trans {
        let mut waveform = el().key("signal").absolute(right + 9.5, 8.).size(52., 28.);
        for i in 0..9 {
            let h = bar_height(s, i, s.now);
            waveform = waveform.child(
                shape(
                    &format!("dot-0-{i}"),
                    i as f32 * 6. + 0.5,
                    14. - h / 2.,
                    3.,
                    h,
                    red(),
                )
                .matched(format!("signal-0-{i}")),
            );
        }
        root = root.child(
            el().key("waveform")
                .opacity(0.)
                .absolute(right + 10., 10.)
                .size(52., 24.),
        );
        if let Some(t) = s.recoverable_since {
            // Keep the take and controls; put the note above the signal, outside the hardware notch.
            root = root.child(
                text(&s.message)
                    .key("recoverable-note")
                    .absolute(right + 8., 0.)
                    .font(TextStyle::new(8., 500.))
                    .color(Color::WHITE)
                    .opacity(ease(((s.now - t) / 0.1) as f32)),
            );
        }
        return root.child(waveform);
    }
    // Icons appear only after the signal centre is inside the left edge of the notch.
    for (key, glyph, ix, delay) in [("Settings", "⚙", 16., 0.26), ("History", "◴", 48., 0.30)] {
        let opacity = if !s.reduced && x >= core {
            0.
        } else {
            ease((age - delay) / 0.15)
        };
        root = root.child(
            button(key, glyph, ix)
                .opacity(opacity * s.content_alpha)
                .scale(if s.reduced { 1. } else { 0.9 + 0.1 * opacity }),
        );
    }
    for side in 0..if s.reduced { 2 } else { 1 } {
        let cx = if s.reduced {
            if side == 0 { start } else { end }
        } else {
            x
        };
        let alpha = if s.reduced {
            if side == 0 {
                1. - ease(age / 0.15)
            } else {
                ease((age - 0.15) / 0.15)
            }
        } else {
            1.
        };
        let spin = if s.reduced {
            if side == 0 { 0. } else { 1. }
        } else {
            ease((age - 0.22) / 0.18)
        };
        let mut group = el()
            .key(if side == 0 {
                "signal"
            } else {
                "reduced-spinner"
            })
            .absolute(cx - 26., 8.)
            .size(52., 28.)
            .opacity(alpha * s.content_alpha);
        for i in 0..9 {
            let base = i as f32 * std::f32::consts::TAU / 9.;
            let angle = base
                + if s.reduced {
                    0.
                } else {
                    (age - 0.4).max(0.) * std::f32::consts::TAU / 0.8
                };
            let dx = (i as f32 * 6. - 24.) * (1. - spin) + angle.cos() * 9. * spin;
            let dy = angle.sin() * 9. * spin;
            let h = 3. + (bar_height(s, i, s.since) - 3.) * (1. - ease(age / 0.1));
            let p = ease(age / 0.1);
            let r = red();
            let b = blue();
            let color = Color {
                r: r.r + (b.r - r.r) * p,
                g: r.g + (b.g - r.g) * p,
                b: r.b + (b.b - r.b) * p,
                a: 1.,
            };
            group = group.child(
                shape(
                    &format!("dot-{side}-{i}"),
                    26. + dx - 1.5,
                    14. + dy - h / 2.,
                    3.,
                    h,
                    color,
                )
                .matched(format!("signal-{side}-{i}"))
                .opacity(1. - spin * (0.35 - 0.35 * base.cos())),
            );
        }
        root = root.child(group);
    }
    root.child(
        shape(
            "notch-occlusion",
            core,
            0.,
            n,
            s.safe_top.min(HEIGHT),
            Color::BLACK,
        )
        .radius(0.)
        .opacity(ease(age / 0.1) * s.content_alpha),
    )
}
fn bar_height(s: &Band, i: usize, t: f64) -> f32 {
    3. + s.rms * 19. * (0.35 + 0.65 * (i as f32 * 1.7 + t as f32 * 5.).sin().abs())
}
fn feedback(s: &Band, core: f32, alpha: f32) -> El {
    text(if s.mode == Mode::Typed {
        "✓ Typed"
    } else {
        &s.message
    })
    .key("feedback")
    .absolute(core - 100., 14.)
    .font(TextStyle::new(11., 500.))
    .color(Color::WHITE)
    .opacity(alpha)
}
pub fn poll(s: &mut Band, clock: f64, tx: &mut Tx) -> bool {
    let active = s.input_active();
    let note = (s.recoverable_since, s.message.clone());
    let before = (s.mode.clone(), s.timer(), s.rms, s.now, s.since);
    if s.live {
        s.advance(clock);
    } else {
        s.sample(clock);
    }
    let changed = before.0 != s.mode;
    if active != s.input_active() && !s.keep_regions {
        if let Some(handle) = &s.overlay {
            handle.set_input(if !s.input_active() {
                OverlayInput::None
            } else {
                OverlayInput::Regions
            });
        }
    }
    let future = s.replay.0.iter().find_map(|e| {
        let t = e["t"].as_f64()?;
        (t > clock).then_some(t)
    });
    let feedback = matches!(s.mode, Mode::Typed | Mode::Error);
    let feedback_enter = s
        .transcribing_since
        .map(|t| (t + 0.45).max(s.since) + 0.12)
        .unwrap_or(s.since);
    let feedback_moving = feedback && (clock < feedback_enter + 0.12 || clock > s.since + 1.05);
    let animated = s
        .recoverable_since
        .is_some_and(|t| clock >= t && clock < t + 0.1)
        || (s.mode == Mode::Idle && s.input_active())
        || s.mode == Mode::Transcribing
        || (s.mode == Mode::Recording && s.rms > 0.)
        || feedback_moving;
    let mut deadline = future;
    if feedback && !feedback_moving {
        deadline = Some(deadline.unwrap_or(f64::INFINITY).min(s.since + 1.05));
    }
    if animated {
        deadline = Some(deadline.unwrap_or(f64::INFINITY).min(clock + 1. / 60.));
    } else if s.mode == Mode::Recording {
        if let Some(first) = s.first_level {
            deadline = Some(
                deadline
                    .unwrap_or(f64::INFINITY)
                    .min(first + (clock - first).floor() + 1.),
            );
        }
    }
    if let Some(t) = deadline {
        tx.wake_at(t);
    }
    (active != s.input_active())
        || note != (s.recoverable_since, s.message.clone())
        || changed
        || before.1 != s.timer()
        || (animated && before.3 != clock)
}
