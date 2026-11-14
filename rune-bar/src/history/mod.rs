//! History is presentation only. Intents contain verbs and a local row ordinal, never archive text/IDs.
pub mod archive;
use rune::{Cx, Drag, El, Key, Phase, ScrollSpec, col, el, row, text};
use rune_kit::{Button, IconButton, Kit, Menu, MenuItem, SegmentedControl};
use serde::{Deserialize, Serialize};
#[derive(Clone, Deserialize, Serialize)]
pub struct Entry {
    pub id: String,
    pub body: String,
    pub created: String,
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub secondary: String,
    #[serde(default)]
    pub status: String,
}
pub fn fixture() -> [Vec<Entry>; 3] {
    serde_json::from_str(include_str!("../../fixtures/history.json")).expect("neutral fixtures")
}
#[derive(Clone)]
pub struct History {
    pub lists: [Vec<Entry>; 3],
    pub category: usize,
    pub limits: [usize; 3],
    pub expanded: Option<usize>,
    pub menu: Option<usize>,
    pub context: Option<rune::PointerPress>,
    pub pull: f32,
    pub at_end: std::rc::Rc<std::cell::Cell<bool>>,
    pub slide: f32,
    pub row_width: f32,
    pub menu_anchor: [f32; 2],
    pub menu_anchors: std::collections::BTreeMap<usize, [f32; 2]>,
    pub axis: i8,
    pub reduce_motion: bool,
    pub intents: Vec<String>,
}
impl History {
    pub fn new(lists: [Vec<Entry>; 3]) -> Self {
        Self {
            lists,
            category: 0,
            limits: [20; 3],
            expanded: None,
            menu: None,
            context: None,
            pull: 0.0,
            at_end: Default::default(),
            slide: 0.0,
            row_width: 656.0,
            menu_anchor: [0.0; 2],
            menu_anchors: Default::default(),
            axis: 0,
            reduce_motion: false,
            intents: vec![],
        }
    }
    pub fn select(&mut self, i: usize) {
        self.category = i.min(2);
        self.expanded = None;
        self.menu = None;
        self.context = None;
        self.slide = 0.0;
        self.axis = 0;
    }
    pub fn count(&self) -> usize {
        self.lists[self.category]
            .len()
            .min(self.limits[self.category])
    }
    pub fn older(&mut self) {
        self.limits[self.category] += 20;
    }
    pub fn emit(&mut self, verb: &str, index: Option<usize>) {
        let line = match index {
            Some(i) => format!("intent {verb} category={} row={i}", self.category),
            None => format!("intent {verb}"),
        };
        println!("{line}");
        self.intents.push(line);
    }
    pub fn release(&mut self) {
        if self.pull >= 1.0 {
            self.emit("open-settings", None);
        }
        self.pull = 0.0;
    }
}
fn age(created: &str) -> String {
    // UTC Gregorian date to epoch; accepts the ISO date prefix written by the archive.
    let b = created.as_bytes();
    let part = |a: usize, z: usize| created.get(a..z).and_then(|s| s.parse::<i64>().ok());
    let stamp = (|| {
        if b.len() < 19 {
            return None;
        }
        let mut y = part(0, 4)?;
        let m = part(5, 7)?;
        let d = part(8, 10)?;
        if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
            return None;
        }
        y -= i64::from(m <= 2);
        let era = y.div_euclid(400);
        let yo = y - era * 400;
        let mp = m + if m > 2 { -3 } else { 9 };
        let days =
            era * 146097 + yo * 365 + yo / 4 - yo / 100 + (153 * mp + 2) / 5 + d - 1 - 719468;
        Some(days * 86400 + part(11, 13)? * 3600 + part(14, 16)? * 60 + part(17, 19)?)
    })();
    let Some(stamp) = stamp else {
        return "Earlier".into();
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let mins = (now - stamp).max(0) / 60;
    if mins < 1 {
        "Just now".into()
    } else if mins < 60 {
        format!("{mins} min ago")
    } else if mins < 1440 {
        format!("{} hr ago", mins / 60)
    } else {
        format!(
            "{} day{} ago",
            mins / 1440,
            if mins / 1440 == 1 { "" } else { "s" }
        )
    }
}
fn pager(s: &mut History, d: &mut Drag, tx: &mut rune::Tx) {
    match d.phase {
        Phase::Down => {
            s.axis = 0;
            s.slide = 0.0
        }
        Phase::Move => {
            if s.axis == 0 && d.dx.abs().max(d.dy.abs()) > 8.0 {
                s.axis = if d.dx.abs() > d.dy.abs() { 1 } else { 2 }
            }
            if s.axis == 1 && !s.reduce_motion {
                s.slide = d.dx
            }
            if s.axis == 2 && s.at_end.get() {
                s.pull = (d.dy / 100.0).clamp(0.0, 1.0)
            }
        }
        Phase::Up => {
            tx.animated();
            if !d.cancelled() && s.axis == 1 && d.dx.abs() > 70.0 {
                s.select(if d.dx < 0.0 {
                    s.category + 1
                } else {
                    s.category.saturating_sub(1)
                })
            }
            s.slide = 0.0;
            if s.axis == 2 {
                if !d.cancelled() {
                    s.release()
                } else {
                    s.pull = 0.0
                }
            }
        }
    };
}
fn entry<S: HistoryHost>(s: &History, category: usize, i: usize, dark: bool) -> El {
    let k = Kit::neutral(dark);
    let t = rune::tok::theme(dark);
    let e = &s.lists[category][i];
    let expanded = s.expanded == Some(i);

    let body_style = rune::tok::type_::BODY;
    let duration_style = body_style.features("'tnum' 1");
    let age_text = age(&e.created);
    let duration_text = e
        .duration_ms
        .map(|ms| {
            let sec = ms.saturating_add(500) / 1000;
            format!("{}:{:02}", sec / 60, sec % 60)
        })
        .unwrap_or_default();
    let duration_width = rune::text::advance(&duration_text, duration_style).max(46.0);
    let timing_width = rune::text::advance(&age_text, body_style) + duration_width + 12.0;
    let available = (s.row_width - 24.0 - timing_width - 40.0).max(24.0);
    let body = if e.body.trim().is_empty() {
        "No text stored"
    } else {
        e.body.trim()
    };
    // Break only the first line around the measured trailing timing and menu.
    // The continuation receives the full row width.
    let mut split = body.len();
    for (at, ch) in body.char_indices() {
        if ch == '\n' || rune::text::advance(&body[..at + ch.len_utf8()], body_style) > available {
            split = at;
            break;
        }
    }
    if split < body.len() {
        if let Some(at) = body[..split].rfind(' ') {
            if at > 0 {
                split = at;
            }
        }
    }
    let more = IconButton::new(&super::MORE)
        .label("Row actions")
        .on_press(move |host: &mut S| {
            let s = host.history_mut();
            {
                s.menu = Some(i);
                s.context = None;
                s.menu_anchor = s.menu_anchors.get(&i).copied().unwrap_or_default();
            }
        })
        .build(&k)
        .key("row-menu")
        .on_layout(move |host: &mut S, rect| {
            let s = host.history_mut();
            {
                s.menu_anchors.insert(i, [rect[0], rect[1] + rect[3]]);
            }
        });
    let timing = row()
        .key("row-time")
        .gap(6.0)
        .child(
            text(age_text)
                .key("row-age")
                .font(body_style)
                .color(t.text_secondary),
        )
        .child(
            text(duration_text)
                .key("row-duration")
                .font(duration_style)
                .w(duration_width)
                .align(rune::Align::End)
                .color(t.text_secondary),
        )
        .child(more);
    let mut block = col().key("row-text").w_full().gap(0.0).child(
        row()
            .w_full()
            .gap(6.0)
            .child(
                text(&body[..split])
                    .key("row-first")
                    .font(body_style)
                    .color(t.text)
                    .grow(1.0)
                    .min_w(0.0),
            )
            .child(timing),
    );
    if expanded {
        if split < body.len() {
            block = block.child(
                text(body[split..].trim())
                    .key("row-continuation")
                    .font(body_style)
                    .color(t.text)
                    .w_full()
                    .wrap(),
            );
        }
        if !e.secondary.is_empty() {
            block = block.child(
                text(&e.secondary)
                    .key("row-question")
                    .font(body_style)
                    .color(t.text_secondary)
                    .w_full()
                    .wrap(),
            );
        }
    } else if split < body.len() {
        block = block.child(
            text(body[split..].trim())
                .key("row-continuation")
                .font(body_style)
                .color(t.text)
                .w_full()
                .max_lines(1),
        );
    }
    if !e.status.is_empty() {
        block = block.child(
            text(&e.status)
                .key("row-status")
                .font(body_style)
                .color(t.text_secondary),
        );
    }
    let mut content = col()
        .key(format!("entry-{i}"))
        .role("listitem")
        .w_full()
        .on_layout(|host: &mut S, r| {
            let s = host.history_mut();
            s.row_width = r[2]
        })
        .padding(12.0)
        .gap(8.0)
        .radius(10.0)
        .fill(t.control_track)
        .token_motion(rune::tok::motion::REFLOW)
        .child(block);
    // Both text styles share a line height and start on the first baseline.
    content = content
        .on_drag(|host: &mut S, d, tx| host.history_drag(d, tx))
        .focusable(true)
        .on_press(move |host: &mut S| {
            let s = host.history_mut();
            s.expanded = if s.expanded == Some(i) { None } else { Some(i) }
        });
    if expanded {
        let mut actions = row().key("row-actions").gap(6.0);
        for (label, verb) in [
            ("Play", "play"),
            ("Copy", "copy"),
            ("Paste", "paste"),
            ("Re-transcribe", "re-transcribe"),
        ] {
            actions = actions.child(
                Button::new(label)
                    .on_press(move |host: &mut S| {
                        let s = host.history_mut();
                        s.emit(verb, Some(i))
                    })
                    .build(&k)
                    .key(format!("action-{verb}")),
            );
        }
        content = content.child(actions);
    }
    content = content.on_secondary_press(move |host: &mut S, p, _| {
        let s = host.history_mut();
        {
            s.menu = Some(i);
            s.context = Some(p)
        }
    });
    content
}

fn menu<S: HistoryHost>(s: &History, k: &Kit, overlays: &mut Vec<El>) -> El {
    let mut menu = Menu::new("history-menu")
        .trigger(el())
        .open(s.menu.is_some())
        .on_close(|host: &mut S| {
            let s = host.history_mut();
            {
                s.menu = None;
                s.context = None
            }
        });
    if let Some(p) = s.context {
        menu = menu.at(p.x, p.y)
    } else {
        menu = menu.at(s.menu_anchor[0], s.menu_anchor[1])
    }
    if let Some(i) = s.menu {
        for (label, verb) in [
            ("Copy ID", "copy-id"),
            ("Copy", "copy"),
            ("Re-transcribe", "re-transcribe"),
            ("Copy logs", "copy-logs"),
            ("Open logs", "open-logs"),
            ("More info", "more-info"),
        ] {
            menu = menu.item(MenuItem::new(label).on_select(move |host: &mut S| {
                let s = host.history_mut();
                {
                    s.emit(verb, Some(i));
                    s.menu = None;
                    s.context = None
                }
            }));
        }
    }
    menu.build(k, overlays)
}

pub trait HistoryHost: 'static {
    fn history_ref(&self) -> &History;
    fn history_mut(&mut self) -> &mut History;
    fn history_select(&mut self, category: usize) {
        self.history_mut().select(category);
    }
    fn hosted() -> bool {
        false
    }
    fn history_drag(&mut self, d: &mut Drag, tx: &mut rune::Tx) {
        pager(self.history_mut(), d, tx)
    }
}
impl HistoryHost for History {
    fn history_ref(&self) -> &History {
        self
    }
    fn history_mut(&mut self) -> &mut History {
        self
    }
}
pub fn view(s: &History, cx: &mut Cx<History>) -> El {
    embedded::<History>(s, cx)
}
pub fn embedded<S: HistoryHost>(s: &History, cx: &mut Cx<S>) -> El {
    embedded_page::<S>(s, s.category, cx)
}
pub fn embedded_page<S: HistoryHost>(s: &History, category: usize, cx: &mut Cx<S>) -> El {
    let dark = cx.system_dark();
    let reduce = s.reduce_motion || cx.system_reduced_motion();
    cx.reduced_motion(reduce);
    let k = Kit::neutral(dark);
    let t = rune::tok::theme(dark);
    let count = s.lists[category].len().min(s.limits[category]);
    let at_end = s.at_end.clone();

    // One stable virtual run: expansion never reparents rows into another run.
    let mut list = col().key("list-content").w_full().gap(8.0).pb(12.0).child(
        col()
            .key("rows")
            .w_full()
            .growth(rune::GrowthSpec::default())
            .virtual_rows(
                count,
                90.0,
                |host: &S, j| {
                    let _ = host.history_ref();
                    format!("entry-{j}").into()
                },
                move |host: &S, j| {
                    let s = host.history_ref();
                    col()
                        .w_full()
                        .pb(8.0)
                        .child(entry::<S>(s, category, j, dark))
                },
            ),
    );
    if count < s.lists[category].len() {
        list = list.child(
            Button::new("Load older")
                .on_press(|host: &mut S| {
                    let s = host.history_mut();
                    s.older()
                })
                .build(&k)
                .key("load-older"),
        );
    }
    if count == 0 {
        list = list.child(text("No history yet").color(t.text_secondary));
    }
    let p = s.pull.clamp(0.0, 1.0);

    let armed = p >= 1.0;
    let label = if armed {
        "Release for Settings"
    } else {
        "Pull for Settings"
    };
    let label_width = rune::text::advance(label, rune::tok::type_::LABEL) + 20.0;
    let width = 40.0 + 200.0 * p;
    let opacity = ((width - label_width - 24.0) / 30.0).clamp(0.0, 1.0);
    let badge = el()
        .key("settings-handle")
        .matched("settings-handle")
        .label(if armed { "armed" } else { "unarmed" })
        .w(width)
        .h(5.0 + 31.0 * p)
        .radius(18.0)
        .fill(if armed { t.text } else { t.text_secondary })
        .token_motion(rune::tok::motion::REFLOW)
        .child(
            row()
                .w_full()
                .h_full()
                .center()
                .gap(6.0)
                .opacity(opacity)
                .opacity_motion(rune::Anim::INSTANT)
                .instant_changes()
                .transition(rune::Transition::none())
                .child(rune::icon(&GEAR, 14.0).color(t.bg))
                .child(
                    text(label)
                        .key("badge-text")
                        .font(rune::tok::type_::LABEL)
                        .color(t.bg),
                ),
        );
    let mut overlays = vec![];
    let menu = menu::<S>(s, &k, &mut overlays);
    col()
        .key("history")
        .w_full()
        .h_full()
        .padding(20.0)
        .gap(16.0)
        .fill(t.bg)
        .on_key(|host: &mut S, e, _| {
            let s = host.history_mut();
            {
                if e.key == Key::Escape {
                    s.expanded = None;
                    s.menu = None;
                    true
                } else {
                    false
                }
            }
        })
        .child(if S::hosted() {
            el()
        } else {
            text("History").font(rune::tok::type_::TITLE).color(t.text)
        })
        .child(
            SegmentedControl::new(&["Dictations", "Ask", "Speech"], Some(category))
                .label("History category")
                .width(if S::hosted() { Some(260.0) } else { None })
                .on_pick(|host: &mut S, i, _| host.history_select(i))
                .build(&k)
                .key("selector")
                .on_key(|host: &mut S, e, _| {
                    let category = host.history_ref().category;
                    match e.key {
                        Key::Left => {
                            host.history_select(category.saturating_sub(1));
                            true
                        }
                        Key::Right => {
                            host.history_select(category + 1);
                            true
                        }
                        _ => false,
                    }
                }),
        )
        .child(
            col()
                .key("viewport")
                .clip_rounded(0.0)
                .w_full()
                .grow(1.0)
                .min_h(0.0)
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .on_scroll_offset(move |p| at_end.set(p.offset[1] >= p.max[1] - 0.5))
                .on_drag(|host: &mut S, d, tx| host.history_drag(d, tx))
                .child(
                    list.offset(if reduce { 0.0 } else { s.slide }, 0.0)
                        .token_motion(rune::tok::motion::REFLOW),
                ),
        )
        .child(
            row()
                .key("pull-zone")
                .w_full()
                .h(if S::hosted() { 0.0 } else { 52.0 })
                .center()
                .label("Pull for Settings")
                .on_drag(|host: &mut S, d: &mut Drag, tx| {
                    let s = host.history_mut();
                    match d.phase {
                        Phase::Down => {}
                        Phase::Move => {
                            if s.at_end.get() {
                                s.pull = (d.dy / 100.0).clamp(0.0, 1.0)
                            }
                        }
                        Phase::Up => {
                            tx.animated();
                            if d.cancelled() {
                                s.pull = 0.0
                            } else {
                                s.release()
                            }
                        }
                    }
                })
                .child(if S::hosted() { el() } else { badge }),
        )
        .child(menu)
        .children(overlays)
}
pub fn key(s: &mut History, e: &rune::KeyEvent, _: &mut rune::Tx) -> bool {
    if e.key == Key::Escape {
        s.expanded = None;
        s.menu = None;
        s.context = None;
        true
    } else {
        false
    }
}

static GEAR: rune::Icon = rune::Icon {
    name: "settings",
    view: 24.0,
    body: r#"<path d="M9 3H15L16 6L19 7L22 11V13L19 17L16 18L15 21H9L8 18L5 17L2 13V11L5 7L8 6Z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="4" fill="none" stroke="currentColor" stroke-width="2"/>"#,
};
