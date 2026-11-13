//! Read-only Dictionary pilot. No backend, capture, clipboard or dictionary writes.
use rune::{Cx, Drag, El, GrowthSpec, Phase, ScrollSpec, TextEdit, col, el, row, text};
use rune_kit::{
    Button, ButtonVariant, Collapsible, ControlSize, IconButton, IconButtonVariant, Kit, Menu,
    MenuItem, ScrollBar, TextInput,
};
use serde::{Deserialize, Serialize};
use std::{
    cell::Cell,
    path::{Path, PathBuf},
};

pub const WIDTH: f32 = 620.0;
pub const DEFAULT_HEIGHT: f32 = 640.0;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Entry {
    pub canonical: String,
    #[serde(default)]
    pub variants: Vec<String>,
}
pub fn included() -> Vec<Entry> {
    serde_json::from_str(include_str!("included.json")).expect("bundled developer vocabulary")
}
pub fn vocabulary_path() -> PathBuf {
    std::env::var("QA_VOICE_STT_VOCABULARY_PATH")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(|v| PathBuf::from(v.trim()))
        .unwrap_or_else(|| home().join(".local/state/voicelayer/stt-vocabulary.json"))
}
fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}
pub fn state_path() -> PathBuf {
    std::env::var_os("VOICELAYER_RUNE_UI_STATE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state/voicelayer/rune-ui.json"))
}
pub fn read_entries(path: &Path) -> Vec<Entry> {
    // Invalid entries are isolated; never report runtime contents in diagnostics.
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v.get("entries")?.as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|v| {
            let canonical = v.get("canonical")?.as_str()?.trim();
            if canonical.is_empty() {
                return None;
            }
            let variants = v
                .get("variants")
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str())
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
                .collect();
            Some(Entry {
                canonical: canonical.to_owned(),
                variants,
            })
        })
        .collect()
}
#[derive(Serialize, Deserialize)]
struct Geometry {
    height: f32,
}
pub fn clamp_height(height: f32, screen: f32) -> f32 {
    if height.is_finite() {
        height.clamp(240.0_f32.min(screen), screen)
    } else {
        DEFAULT_HEIGHT.min(screen)
    }
}
pub fn load_height(path: &Path, screen: f32) -> f32 {
    let height = std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Geometry>(&b).ok())
        .map(|g| g.height)
        .unwrap_or(DEFAULT_HEIGHT);
    clamp_height(height, screen)
}
pub fn save_height(path: &Path, height: f32, screen: f32) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let bytes = serde_json::to_vec(&Geometry {
        height: clamp_height(height, screen),
    })?;
    let temp = path.with_extension("json.new");
    std::fs::write(&temp, bytes)?;
    std::fs::rename(temp, path)
}
pub struct Dictionary {
    pub personal: Vec<Entry>,
    pub bundled: Vec<Entry>,
    pub search: TextEdit,
    pub expanded: [bool; 2],
    pub selected: Option<String>,
    pub open_menu: Option<String>,
    pub height: f32,
    pub screen: f32,
    pub state_file: Option<PathBuf>,
    pub persisted: Cell<f32>,
    pub observed_height: Cell<f32>,
    pub observed_width: Cell<f32>,
    pub resize_due: Option<f64>,
}
impl Dictionary {
    pub fn new(personal: Vec<Entry>, screen: f32, state_file: Option<PathBuf>) -> Self {
        let height = state_file
            .as_ref()
            .map(|p| load_height(p, screen))
            .unwrap_or(DEFAULT_HEIGHT.min(screen));
        Self {
            personal,
            bundled: included(),
            search: TextEdit::new(""),
            expanded: [true, true],
            selected: None,
            open_menu: None,
            height,
            screen,
            state_file,
            persisted: Cell::new(height),
            observed_height: Cell::new(height),
            observed_width: Cell::new(WIDTH),
            resize_due: None,
        }
    }
    pub fn matches(&self, group: usize) -> Vec<usize> {
        let query = &self.search.text;
        let fold = rune_kit::search::Fold::default();
        self.entries(group)
            .iter()
            .enumerate()
            .filter(|(_, e)| {
                fold.contains(&e.canonical, query)
                    || e.variants.iter().any(|v| fold.contains(v, query))
            })
            .map(|(i, _)| i)
            .collect()
    }
    fn entries(&self, group: usize) -> &[Entry] {
        if group == 0 {
            &self.personal
        } else {
            &self.bundled
        }
    }
    pub fn observe_resize(&mut self, height: f32, now: f64) {
        self.observed_height.set(clamp_height(height, self.screen));
        self.resize_due = Some(now + 0.3);
    }
    pub fn flush_resize(&mut self, now: f64) {
        if self.resize_due.is_some_and(|due| now >= due) {
            self.persist(self.observed_height.get());
            self.resize_due = None;
        }
    }
    pub fn persist(&self, height: f32) {
        let h = clamp_height(height, self.screen);
        self.observed_height.set(h);
        if (self.persisted.get() - h).abs() < 0.5 {
            return;
        }
        if let Some(path) = &self.state_file {
            match save_height(path, h, self.screen) {
                Ok(()) => self.persisted.set(h),
                Err(_) => eprintln!("Rune UI geometry could not be saved"),
            }
        }
    }
}
pub fn fixture() -> Vec<Entry> {
    vec![
        Entry {
            canonical: "Rust".into(),
            variants: vec![],
        },
        Entry {
            canonical: "Cargo workspace".into(),
            variants: vec!["cargo work space".into(), "cargo project".into()],
        },
        Entry {
            canonical: "TypeScript".into(),
            variants: vec!["type script".into()],
        },
        Entry {
            canonical: "Render pipeline".into(),
            variants: vec!["render pipe line".into()],
        },
    ]
}
static PLUS: rune::Icon = rune::Icon {
    name: "plus",
    view: 24.0,
    body: r#"<path d="M12 5V19M5 12H19" fill="none" stroke="currentColor" stroke-width="1.5"/>"#,
};
static PENCIL: rune::Icon = rune::Icon {
    name: "pencil",
    view: 24.0,
    body: r#"<path d="M4 17L16 5L19 8L7 20H4V17Z" fill="none" stroke="currentColor" stroke-width="1.5"/>"#,
};
static MORE: rune::Icon = rune::Icon {
    name: "more",
    view: 24.0,
    body: r#"<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>"#,
};
fn term_row<S: DictionaryHost>(s: &Dictionary, group: usize, index: usize, dark: bool) -> El {
    let k = Kit::neutral(dark);
    let t = rune::tok::theme(dark);
    let e = &s.entries(group)[index];
    let id = format!("term-{group}-{index}");
    let selected = s.selected.as_ref() == Some(&id);
    let mut labels = col().key("text-block").gap(3.0).grow(1.0).min_w(0.0).child(
        text(&e.canonical)
            .font(rune::tok::type_::BODY)
            .color(t.text)
            .truncate(),
    );
    if let Some(first) = e.variants.first() {
        let more = if e.variants.len() > 1 {
            format!(" +{} more", e.variants.len() - 1)
        } else {
            String::new()
        };
        labels = labels.child(
            text(format!("also heard as \u{2068}{first}\u{2069}{more}"))
                .font(rune::tok::type_::LABEL)
                .color(t.text_secondary)
                .truncate(),
        );
    }
    let mut overlays = Vec::new();
    let menu_id = id.clone();
    let menu = Menu::new(format!("{id}-actions"))
        .trigger(
            IconButton::new(&MORE)
                .label("Term actions")
                .variant(IconButtonVariant::Ghost)
                .expanded(s.open_menu.as_ref() == Some(&id))
                .on_press(move |host: &mut S| {
                    let s = host.dictionary_mut();
                    {
                        s.open_menu = if s.open_menu.as_ref() == Some(&menu_id) {
                            None
                        } else {
                            Some(menu_id.clone())
                        };
                    }
                })
                .build(&k)
                .key("menu"),
        )
        .open(s.open_menu.as_ref() == Some(&id))
        .item(
            MenuItem::new("Copy")
                .disabled(!S::hosted())
                .on_select(|s: &mut S| s.dictionary_intent("copy-term")),
        )
        .item(
            MenuItem::new("Delete")
                .disabled(!S::hosted())
                .on_select(|s: &mut S| s.dictionary_intent("delete-term")),
        )
        .on_close(|host: &mut S| {
            let s = host.dictionary_mut();
            s.open_menu = None
        })
        .build(&k, &mut overlays);
    row()
        .key(&id)
        .role("listitem")
        .focus_selected(selected)
        .label(&e.canonical)
        .w_full()
        .h(if e.variants.is_empty() { 48.0 } else { 64.0 })
        .px(12.0)
        .gap(8.0)
        .center_y()
        .radius(rune::tok::radius::MD)
        .fill(if selected {
            // Quiet neutral selection, bounded in both themes by the pixel test.
            k.alpha(t.text, 0.05)
        } else {
            rune::Color::TRANSPARENT
        })
        .hover(t.hover)
        .focusable(true)
        .on_press(move |host: &mut S| {
            let s = host.dictionary_mut();
            s.selected = Some(id.clone())
        })
        .child(labels)
        .child(
            IconButton::new(&PENCIL)
                .label("Edit term")
                .variant(IconButtonVariant::Ghost)
                .on_press(|host: &mut S| host.dictionary_intent("edit-term"))
                .build(&k)
                .key("pencil"),
        )
        .child(menu)
        .children(overlays)
}
pub trait DictionaryHost: 'static {
    fn dictionary_ref(&self) -> &Dictionary;
    fn dictionary_mut(&mut self) -> &mut Dictionary;
    fn hosted() -> bool {
        false
    }
    fn dictionary_intent(&mut self, _verb: &str) {}
}
impl DictionaryHost for Dictionary {
    fn dictionary_ref(&self) -> &Dictionary {
        self
    }
    fn dictionary_mut(&mut self) -> &mut Dictionary {
        self
    }
}
pub fn view(s: &Dictionary, cx: &mut Cx<Dictionary>) -> El {
    embedded::<Dictionary>(s, cx)
}
pub fn embedded<S: DictionaryHost>(s: &Dictionary, cx: &mut Cx<S>) -> El {
    let dark = cx.system_dark();
    let k = Kit::neutral(dark);
    let t = rune::tok::theme(dark);
    let mut content = col().w_full().gap(4.0);
    for group in 0..2 {
        let indices = s.matches(group);
        let title = format!(
            "{} ({})",
            if group == 0 {
                "Your terms"
            } else {
                "Included terms"
            },
            indices.len()
        );
        let header = Collapsible::new(title, s.expanded[group])
            .ghost()
            .on_toggle(move |host: &mut S| {
                let s = host.dictionary_mut();
                s.expanded[group] = !s.expanded[group]
            })
            .build(&k)
            .key(format!("group-{group}"));
        if group > 0 {
            content = content.child(el().h(24.0));
        }
        content = content.child(header);
        if s.expanded[group] {
            let keys = indices.clone();
            content = content.child(
                col()
                    .key(format!("rows-{group}"))
                    .w_full()
                    .growth(GrowthSpec::default())
                    .virtual_rows(
                        indices.len(),
                        64.0,
                        move |host: &S, i| {
                            let _ = host.dictionary_ref();
                            format!("term-{group}-{}", keys[i]).into()
                        },
                        move |host: &S, i| {
                            let s = host.dictionary_ref();
                            term_row::<S>(s, group, indices[i], dark)
                        },
                    ),
            );
        }
    }
    let control_size = ControlSize::ExtraLarge;
    let add = Button::new("Add term")
        .control_size(control_size)
        .variant(ButtonVariant::Neutral)
        .icon(&PLUS)
        .on_press(|host: &mut S| host.dictionary_intent("add-term"))
        .build(&k)
        .fill(k.c.bg_base)
        .key("add");
    // TextInput has a height override but no ControlSize API: take the kit button metric.
    let control_height = match control_size {
        ControlSize::ExtraLarge => 36.0,
        _ => unreachable!("toolbar size"),
    };
    let body = col()
        .key("body")
        .w_full()
        .grow(1.0)
        .min_h(0.0)
        .padding(24.0)
        .gap(16.0)
        .child(
            if S::hosted() { el() } else { text("Dictionary")
                .font(rune::TextStyle {
                    size: 24.0,
                    ..rune::tok::type_::TITLE
                })
                .color(t.text) },
        )
        .child(
            row()
                .key("toolbar")
                .gap(8.0)
                .center_y()
                .child(
                    TextInput::new(&s.search)
                        .placeholder("Search terms and variants")
                        .label("Search terms and variants")
                        .height(control_height)
                        .leading_icon(&rune_kit::glyphs::SEARCH)
                        .on_edit(|host: &mut S| {
                            let s = host.dictionary_mut();
                            &mut s.search
                        })
                        .on_change(|host: &mut S, tx| {
                            let _ = host.dictionary_mut();
                            tx.scroll_to_instant("viewport", 0.0, 0.0)
                        })
                        .build(&k)
                        .key("search")
                        .grow(1.0),
                )
                .child(add),
        )
        .child(
            col()
                .key("viewport")
                .grow(1.0)
                .min_h(0.0)
                .w_full()
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .child(content)
                .scroll_bar(&k),
        );
    col()
        .key("dictionary")
        .w_full()
        .h_full()
        .fill(t.bg)
        .child(body)
        .child(
            col()
                .key("bottom-edge")
                .center()
                .child(
                    el().key("resize-mark")
                        .w(if S::hosted() { 0.0 } else { 40.0 })
                        .h(3.0)
                        .radius(2.0)
                        .fill(t.text_secondary),
                )
                .w_full()
                .h(if S::hosted() { 0.0 } else { 8.0 })
                .role("separator")
                .label("Resize Dictionary height")
                .cursor(rune::Cursor::ResizeRow)
                .on_drag(|host: &mut S, d: &mut Drag, tx| {
                    let s = host.dictionary_mut();
                    match d.phase {
                        Phase::Down => d.data = s.observed_height.get(),
                        Phase::Move => {
                            s.height = clamp_height(d.data + d.dy, s.screen);
                            tx.resize_window_instant((s.observed_width.get(), s.height));
                        }
                        Phase::Up => {
                            s.persist(s.height);
                        }
                    }
                }),
        )
}

pub mod band;
pub mod history;

pub mod settings;
