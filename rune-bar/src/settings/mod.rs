//! Settings is a presentation host: actions print intents; only drawer geometry persists.
pub mod snapshot;
use crate::{
    Dictionary, DictionaryHost,
    history::{self, History, HistoryHost},
};
use rune::{Cx, Drag, El, Key, Phase, ScrollSpec, col, el, row, text};
use rune_kit::{Button, Kit, SegmentedControl, Select, Switch};
use snapshot::{SettingsSnapshot, Polish};
use std::path::PathBuf;
pub const TABS: [&str; 5] = [
    "General",
    "Transcription",
    "Dictionary",
    "Speech",
    "History",
];
pub const MIN_HEIGHT: f32 = 540.0;
pub struct Settings {
    pub snapshot: SettingsSnapshot,
    pub dictionary: Dictionary,
    pub history: History,
    pub tab: usize,
    pub height: f32,
    pub screen: f32,
    pub width: f32,
    pub state_path: Option<PathBuf>,
    pub slide: f32,
    pub axis: i8,
    pub drag_origin: usize,
    pub reduce_motion: bool,
    pub open: Option<String>,
    pub threshold: rune::TextEdit,
    pub intents: Vec<String>,
}
impl DictionaryHost for Settings {
    fn dictionary_ref(&self) -> &Dictionary {
        &self.dictionary
    }
    fn dictionary_mut(&mut self) -> &mut Dictionary {
        &mut self.dictionary
    }
    fn dictionary_intent(&mut self, verb: &str) {
        self.emit(verb)
    }
    fn hosted() -> bool {
        true
    }
}
impl HistoryHost for Settings {
    fn history_ref(&self) -> &History {
        &self.history
    }
    fn history_mut(&mut self) -> &mut History {
        &mut self.history
    }
    fn history_drag(&mut self, d: &mut Drag, tx: &mut rune::Tx) {
        pager(self, d, tx)
    }
    fn hosted() -> bool {
        true
    }
}
impl Settings {
    pub fn new(snapshot: SettingsSnapshot, screen: f32, path: Option<PathBuf>) -> Self {
        let height = path
            .as_ref()
            .map(|p| crate::load_height(p, screen))
            .unwrap_or(640.0)
            .clamp(MIN_HEIGHT.min(screen), screen);
        let threshold = rune::TextEdit::new(
            snapshot
                .threshold
                .map(|n| n.to_string())
                .unwrap_or_default(),
        );
        Self {
            snapshot,
            dictionary: Dictionary::new(crate::fixture(), screen, None),
            history: History::new(history::fixture()),
            tab: 0,
            height,
            screen,
            width: 720.0,
            state_path: path,
            slide: 0.0,
            axis: 0,
            drag_origin: 0,
            reduce_motion: false,
            open: None,
            threshold,
            intents: vec![],
        }
    }
    pub fn emit(&mut self, action: &str) {
        let line = format!("intent: {action}");
        println!("{line}");
        self.intents.push(line);
    }
    pub fn change(&mut self, operation: &str, from: &str, to: &str) {
        self.emit(&format!("{operation} from={from} to={to} rev={}", self.snapshot.revision));
    }
    pub fn page(&self) -> usize {
        if self.tab == 4 {
            4 + self.history.category
        } else {
            self.tab
        }
    }
    pub fn select_page(&mut self, page: usize) {
        let p = page.min(6);
        self.tab = p.min(4);
        if p >= 4 {
            self.history.select(p - 4);
        }
        self.open = None;
    }
    pub fn select_tab(&mut self, tab: usize) {
        self.tab = tab.min(4);
        self.open = None;
        self.slide = 0.0;
    }
}
fn pager(s: &mut Settings, d: &mut Drag, tx: &mut rune::Tx) {
    match d.phase {
        Phase::Down => {
            s.axis = 0;
            s.drag_origin = s.page();
        }
        Phase::Move => {
            if s.axis == 0 && d.dx.abs().max(d.dy.abs()) > 8.0 {
                s.axis = if d.dx.abs() > d.dy.abs() { 1 } else { 2 };
            }
            if s.axis == 1 {
                // Consume each page of a continuous drag, including History's three lists.
                let step = (-d.dx / s.width).round() as isize;
                s.select_page((s.drag_origin as isize + step).clamp(0, 6) as usize);
                s.slide = if s.reduce_motion {
                    0.0
                } else {
                    {
                        let raw = d.dx + (s.page() as f32 - s.drag_origin as f32) * s.width;
                        if (s.page() == 0 && raw > 0.0) || (s.page() == 6 && raw < 0.0) { raw / (1.0 + raw.abs() / 120.0) } else { raw }
                    }
                };
            }
        }
        Phase::Up => {
            if !d.cancelled() && s.axis == 1 && (d.dx / s.width).round() == 0.0 && d.dx.abs() > 70.0
            {
                s.select_page(
                    (s.drag_origin as isize + if d.dx < 0.0 { 1 } else { -1 }).clamp(0, 6)
                        as usize,
                );
            }
            if d.cancelled() {
                s.select_page(s.drag_origin);
            }
            s.slide = 0.0;
            s.axis = 0;
            tx.animated();
        }
    }
}
fn button(label: &str, action: String, k: &Kit) -> El {
    Button::new(label)
        .on_press(move |s: &mut Settings| {
            match action.as_str() {
                "hide 1h" | "show" => { if let Some(v) = s.snapshot.visible { s.change("set-visibility", if v {"shown"} else {"hidden"}, if action == "show" {"shown"} else {"hidden-1h"}); } }
                "recognizer-toggle" => { if let Some(v) = s.snapshot.resident { s.change("set-residency", if v {"loaded"} else {"unloaded"}, if v {"unloaded"} else {"loaded"}); } }
                _ => s.emit(&action),
            }
        })
        .build(k)
        .h(36.0)
        .key(action_key(label))
}
fn action_key(label: &str) -> String {
    label.to_lowercase().replace(' ', "-")
}
fn value(v: Option<&str>, dark: bool) -> El {
    text(v.unwrap_or("Unavailable here"))
        .font(rune::tok::type_::BODY)
        .color(if v.is_some() {
            rune::tok::theme(dark).text
        } else {
            rune::tok::theme(dark).text_secondary
        })
}
fn setting(label: &str, control: El, dark: bool) -> El {
    row()
        .key(format!("row-{}", action_key(label)))
        .w_full()
        .min_h(44.0)
        .center_y()
        .gap(12.0)
        .child(
            text(label)
                .font(rune::tok::type_::BODY)
                .color(rune::tok::theme(dark).text)
                .grow(1.0),
        )
        .child(control)
}
fn tag(label: &str, dark: bool) -> El { text(label).font(rune::tok::type_::LABEL).color(rune::tok::theme(dark).text_secondary) }
fn section(title: &str, dark: bool) -> El {
    text(title)
        .font(rune::tok::type_::LABEL)
        .color(rune::tok::theme(dark).text_secondary)
        .pt(12.0)
}
fn lock(var: &Option<String>, dark: bool) -> El {
    if let Some(var) = var {
        rune::icon(&LOCK, 14.0)
            .key("lock")
            .color(rune::tok::theme(dark).text_secondary)
            .help(var)
    } else {
        el()
    }
}
fn choice(
    s: &Settings,
    id: &str,
    current: Option<&str>,
    options: &[String],
    k: &Kit,
    overlays: &mut Vec<El>,
) -> El {
    let a = id.to_owned();
    let b = a.clone();
    let c = a.clone();
    Select::new(id, options)
        .label(id)
        .current(current)
        .placeholder("Unavailable here")
        .width(180.0)
        .open(s.open.as_deref() == Some(id))
        .on_toggle(move |s: &mut Settings| {
            s.open = if s.open.as_deref() == Some(&a) {
                None
            } else {
                Some(a.clone())
            }
        })
        .on_close(|s: &mut Settings| s.open = None)
        .on_choose(move |s: &mut Settings, v: &str, _| {
            let i = usize::from(b.starts_with("Long"));
            let from = s.snapshot.voices[i].clone();
            if s.snapshot.speech_locks[i*2].is_none() { if let Some(from) = from { s.change(&format!("set-{b}"), &from, v); } }
            s.open = None;
        })
        .build(k, overlays)
        .key(c)
}
// Keep headers attached to their rows while extra drawer height separates groups.
struct Form {
    groups: Vec<El>,
    current: El,
    populated: bool,
}
impl Form {
    fn new() -> Self {
        Self {
            groups: vec![],
            current: col().w_full().gap(6.0),
            populated: false,
        }
    }
    fn child(mut self, e: El) -> Self {
        self.current = self.current.child(e);
        self.populated = true;
        self
    }
    fn section(mut self, title: &str, dark: bool) -> Self {
        if self.populated {
            self.groups.push(self.current);
        }
        self.current = col().w_full().gap(6.0).child(section(title, dark));
        self.populated = true;
        self
    }
    fn build(mut self) -> El {
        if self.populated {
            self.groups.push(self.current);
        }
        col()
            .w_full()
            .h_full()
            .min_h(360.0)
            .justify_between()
            .children(self.groups)
    }
}
fn panel(s: &Settings, tab: usize, dark: bool, k: &Kit, overlays: &mut Vec<El>) -> El {
    let v = &s.snapshot;
    let mut content = Form::new();
    match tab {
        0 => {
            if let Some(steps) = &v.setup {
                let broken: Vec<_> = steps.iter().filter(|(_, ok)| !*ok).collect();
                if !broken.is_empty() {
                    content = content.section("Setup", dark);
                }
                for (name, _) in broken {
                    content = content.child(setting(
                        name,
                        button("Fix", format!("fix {}", action_key(name)), k),
                        dark,
                    ));
                }
            } else {
                content = content.child(setting("Setup", value(None, dark), dark));
            }
            let mut key = row()
                .center_y()
                .gap(8.0)
                .child(value(v.dictation_key.as_deref(), dark))
                .child(button("Check shortcut", "check-shortcut".into(), k));
            if v.f5_helper == Some(false) {
                key = key.child(button("Fix F5 helper", "fix-f5-helper".into(), k));
            }
            content = content
                .section("Controls", dark)
                .child(setting("Dictation key", key, dark))
                .child(setting(
                    "Visibility",
                    row()
                        .center_y()
                        .gap(8.0)
                        .child(value(
                            v.visible.map(|b| if b { "Shown" } else { "Hidden" }),
                            dark,
                        ))
                        .child(match v.visible { Some(true) => button("Hide for 1 hour", "hide 1h".into(), k), Some(false) => button("Show", "show".into(), k), None => el() }),
                    dark,
                ))
                .section("Microphone priority", dark);
            if let Some(mics) = &v.microphones {
                for (i, mic) in mics.iter().enumerate() {
                    let mut controls = row().gap(8.0).center_y();
                    if i == 0 { controls = controls.child(tag("Default", dark)); }
                    else {
                        let to = mic.clone();
                        controls = controls.child(Button::new("Make default").on_press(move |s: &mut Settings| { if let Some(from) = s.snapshot.default_microphone.clone() { s.change("microphone-default", &from, &to); } }).build(k).h(36.0).key(format!("make-default-{i}")));
                    }
                    content = content.child(setting(mic, controls, dark).child(tag(&(i+1).to_string(), dark)));
                }
            } else {
                content = content.child(value(None, dark));
            }
            content = content
                .section("Last dictation", dark)
                .child(setting("Age", value(v.last_age.as_deref(), dark), dark))
                .child(setting(
                    "Length",
                    value(v.last_length.as_deref(), dark),
                    dark,
                ));
        }
        1 => {
            content = content.section("Recognizer", dark).child(setting(
                "Local recognizer",
                row()
                    .center_y()
                    .gap(8.0)
                    .child(value(v.recognizer.as_deref(), dark))
                    .child(if v.resident.is_none() { el() } else { button(
                        if v.resident == Some(true) {
                            "Unload"
                        } else {
                            "Load"
                        },
                        "recognizer-toggle".into(),
                        k,
                    ) }),
                dark,
            ));
            if v.resident.is_none() {
                content = content.child(setting("Residency", value(None, dark), dark));
            }
            content = content.section("Recognizer details", dark).child(row().w_full().gap(12.0)
                .child(el().w(90.0)).child(tag("Configured", dark).w(215.0)).child(tag("Active", dark).grow(1.0)));
            for (label, a, b) in [
                (
                    "Model",
                    v.configured_model.as_deref(),
                    v.active_model.as_deref(),
                ),
                (
                    "Effort",
                    v.configured_effort.as_deref(),
                    v.active_effort.as_deref(),
                ),
            ] {
                content = content.child(
                    row()
                        .w_full()
                        .gap(12.0)
                        .child(text(label).w(90.0).color(rune::tok::theme(dark).text))
                        .child(value(a, dark).w(215.0))
                        .child(row().grow(1.0).center_y().gap(8.0).child(value(b, dark)).child(if label == "Effort" { lock(&v.effort_lock, dark) } else { el() })),
                );
            }
            content = content.section("Processing", dark);
            for (i, (label, key)) in [
                ("Model polish", "polish"),
                ("Closing-phrase filter", "outro"),
                ("Smart chunks", "smart-chunks"),
            ]
            .iter()
            .enumerate()
            {
                let key = key.to_string();
                let mut controls = row().center_y().gap(8.0);
                if let Some(enabled) = v.processing[i] {
                    if i == 0 && v.polish == Some(Polish::Shadow) {
                        controls = controls.child(tag("Shadow", dark));
                    } else {
                        controls = controls.child(Switch::new(enabled).label(*label).hide_label()
                            .on_toggle(move |s: &mut Settings| {
                                if s.snapshot.processing_locks[i].is_none() {
                                    s.change(&format!("set-processing {key}"), if enabled {"on"} else {"off"}, if enabled {"off"} else {"on"});
                                }
                            }).build(k).key(format!("toggle-{i}")));
                    }
                    controls = controls.child(lock(&v.processing_locks[i], dark));
                } else { controls = controls.child(value(None, dark)); }
                let label = if i == 2 { row().grow(1.0).gap(8.0).center_y().child(value(Some(label), dark)).child(tag("Experimental", dark)) } else { value(Some(label), dark).grow(1.0) };
                content = content.child(row().w_full().min_h(44.0).center_y().gap(12.0).child(label).child(controls));
            }
        }
        3 => {
            for (i, label) in ["Short", "Long"].iter().enumerate() {
                content = content.section(label, dark);
                let voice = if v.voices[i].is_some() { choice(s, &format!("{label}-voice"), v.voices[i].as_deref(), &v.available_voices, k, overlays) } else { value(None, dark) };
                let mut rate = row().center_y().gap(12.0);
                if let (Some(raw),Some(min),Some(max),Some(step)) = (v.rates[i].as_deref(),v.rate_min,v.rate_max,v.rate_step) {
                    if let Ok(n) = raw.trim_end_matches('%').parse::<i32>() {
                        for (name, delta) in [("−", -step), ("+", step)] {
                            if delta > 0 { rate = rate.child(value(Some(raw), dark)); }
                            let operation = format!("set-{label}-rate"); let from = raw.to_string();
                            rate = rate.child(Button::new(name).disabled(n+delta < min || n+delta > max)
                                .on_press(move |s: &mut Settings| { if s.snapshot.speech_locks[i*2+1].is_none() { s.change(&operation, &from, &format!("{:+}%", (n+delta).clamp(min,max))); } })
                                .build(k).h(36.0).key(format!("{label}-rate-{}",if delta<0 {"minus"} else {"plus"})));
                        }
                    } else { rate = rate.child(value(None,dark)); }
                } else { rate = rate.child(value(None,dark)); }
                content = content
                    .child(
                        setting(
                            "Voice",
                            row()
                                .center_y()
                                .gap(8.0)
                                .child(lock(&v.speech_locks[i * 2], dark))
                                .child(voice),
                            dark,
                        )
                        .key(format!("{label}-voice-row")),
                    )
                    .child(
                        setting(
                            "Rate",
                            row()
                                .center_y()
                                .gap(8.0)
                                .child(lock(&v.speech_locks[i * 2 + 1], dark))
                                .child(rate),
                            dark,
                        )
                        .key(format!("{label}-rate-row")),
                    );
            }
            let field = row().w(100.0).h(36.0).center_y().px(8.0).fill(k.c.bg_base).border(1.0, k.c.border_base).radius(6.0).key("threshold")
                .child(rune::text_input(&s.threshold, rune::TextStyle { line_height: 20.0, ..rune::tok::type_::BODY })
                    .color(rune::tok::theme(dark).text).single_line()
                    .on_edit(|s: &mut Settings| &mut s.threshold).label("Long text from").w_full().h(20.0).key("threshold-text"));
            let mut threshold = row().center_y().gap(8.0).child(lock(&v.threshold_lock,dark));
            if v.threshold.is_some() {
                threshold = threshold.child(field).child(value(Some("characters"),dark));
                if s.threshold.text != v.threshold.unwrap().to_string() {
                    threshold = threshold.child(Button::new("Apply").on_press(|s: &mut Settings| {
                        if s.snapshot.threshold_lock.is_none() { if let (Some(from),Ok(to))=(s.snapshot.threshold,s.threshold.text.parse::<u64>()) { s.change("set-threshold", &from.to_string(), &to.to_string()); } }
                    }).build(k).h(36.0).key("apply"))
                    .child(Button::new("Revert").on_press(|s: &mut Settings| { s.threshold = rune::TextEdit::new(s.snapshot.threshold.map(|n|n.to_string()).unwrap_or_default()); }).build(k).h(36.0).key("revert"));
                }
            } else { threshold = threshold.child(value(None,dark)); }
            content = content.section("Playback",dark)
                .child(setting("Long text from",threshold,dark).key("threshold-row"))
                .child(setting("Clone",value(v.clone_status.as_deref(),dark),dark))
                .child(setting("",button("Preview","speech-preview".into(),k),dark));
        }
        _ => {}
    }
    // Rows remain grouped at the top; the footer follows the drawer's bottom.
    let footer = if tab == 0 {
        row()
            .w_full()
            .center_y()
            .child(value(v.version.as_deref(), dark).grow(1.0))
            .child(button("Copy", "copy-diagnostics".into(), k))
    } else if tab == 3 {
        row()
            .w_full()
            .child(button("Preview", "speech-preview".into(), k))
    } else {
        row().w_full().child(value(Some("Read-only"), dark))
    };
    col()
        .w_full()
        .h_full()
        .padding(20.0)
        .child(
            col()
                .w_full()
                .grow(1.0)
                .min_h(0.0)
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .child(content.build()),
        )
        .child(footer.key("panel-last-row").h(40.0))
}
pub fn view(s: &Settings, cx: &mut Cx<Settings>) -> El {
    let dark = cx.system_dark();
    let reduce = s.reduce_motion || cx.system_reduced_motion();
    cx.reduced_motion(reduce);
    let t = rune::tok::theme(dark);
    let mut k = Kit::neutral(dark);
    k.c.layer_04 = t.control_track;
    let mut overlays = vec![];
    let mut page_body = |page: usize| {
        let tab = page.min(4);
        let body = match tab {
            2 => crate::embedded::<Settings>(&s.dictionary, cx),
            4 => history::embedded_page::<Settings>(&s.history, page - 4, cx),
            _ => panel(s, tab, dark, &k, &mut overlays),
        };
        col().w(s.width).h_full().instant_changes().child(body)
    };
    // Absolute page positions retain identity when release changes the selected page.
    let mut body = row().w(s.width * 7.0).h_full();
    for page in 0usize..7 {
        body = body.child(if page.abs_diff(s.page()) <= 1 {
            page_body(page).key(format!("page-{page}"))
        } else { el().w(s.width).h_full().key(format!("page-{page}")) });
    }
    let body = body.offset(-(s.page() as f32) * s.width + if reduce { 0.0 } else { s.slide }, 0.0);
    col()
        .key("settings")
        .w_full()
        .h_full()
        .fill(t.bg)
        .on_layout(|s: &mut Settings, r| {
            s.width = r[2];
            s.height = r[3];
        })
        .child(
            SegmentedControl::new(&TABS, Some(s.tab))
                .width(None)
                .on_pick(|s: &mut Settings, i, _| s.select_tab(i))
                .build(&k)
                .key("tabs")
                .on_key(|s: &mut Settings, e, _| match e.key {
                    Key::Left => {
                        s.select_tab(s.tab.saturating_sub(1));
                        true
                    }
                    Key::Right => {
                        s.select_tab(s.tab + 1);
                        true
                    }
                    _ => false,
                }),
        )
        .child(
            col()
                .key("pager")
                .w_full()
                .grow(1.0)
                .min_h(0.0)
                .clip_rounded(0.0)
                .on_drag(pager)
                .child(if s.axis == 1 {
                    body.offset_motion(rune::Anim::INSTANT)
                } else {
                    body.token_motion(rune::tok::motion::REFLOW)
                }),
        )
        .child(
            row()
                .key("settings-bottom-edge")
                .w_full()
                .h(16.0)
                .center()
                .cursor(rune::Cursor::ResizeRow)
                .on_drag(|s: &mut Settings, d: &mut Drag, tx| match d.phase {
                    Phase::Down => d.data = s.height,
                    Phase::Move => {
                        s.height = (d.data + d.dy).clamp(MIN_HEIGHT.min(s.screen), s.screen);
                        tx.resize_window_instant((s.width, s.height));
                    }
                    Phase::Up => {
                        if let Some(p) = &s.state_path {
                            let _ = crate::save_height(p, s.height, s.screen);
                        }
                    }
                })
                .child(el().w(40.0).h(3.0).radius(2.0).fill(t.text_secondary)),
        )
        .children(overlays)
}
static LOCK: rune::Icon = rune::Icon {
    name: "lock",
    view: 24.0,
    body: r#"<rect x="5" y="10" width="14" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="2"/>"#,
};
