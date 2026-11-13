//! Read-only Dictionary pilot. No backend, capture, clipboard or dictionary writes.
use rune::{Cx, Drag, El, GrowthSpec, Phase, ScrollSpec, TextEdit, col, el, row, text};
use rune_kit::{Button, Collapsible, IconButton, Kit, Menu, MenuItem, TextInput};
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
    // All-or-empty for malformed snapshots; never report their contents in diagnostics.
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| serde_json::from_value::<Vec<Entry>>(v.get("entries")?.clone()).ok())
        .unwrap_or_default()
        .into_iter()
        .filter(|e| !e.canonical.trim().is_empty())
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
        }
    }
    pub fn matches(&self, group: usize) -> Vec<usize> {
        let query = self.search.text.to_lowercase();
        self.entries(group)
            .iter()
            .enumerate()
            .filter(|(_, e)| {
                e.canonical.to_lowercase().contains(&query)
                    || e.variants.iter().any(|v| v.to_lowercase().contains(&query))
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
fn term_row(s: &Dictionary, group: usize, index: usize, dark: bool) -> El {
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
                .expanded(s.open_menu.as_ref() == Some(&id))
                .on_press(move |s: &mut Dictionary| {
                    s.open_menu = if s.open_menu.as_ref() == Some(&menu_id) {
                        None
                    } else {
                        Some(menu_id.clone())
                    };
                })
                .build(&k)
                .key("menu"),
        )
        .open(s.open_menu.as_ref() == Some(&id))
        .item(MenuItem::new("Copy").disabled(true))
        .item(MenuItem::new("Delete").disabled(true))
        .on_close(|s: &mut Dictionary| s.open_menu = None)
        .build(&k, &mut overlays);
    row()
        .key(&id)
        .role("listitem")
        .focus_selected(selected)
        .label(&e.canonical)
        .w_full()
        .h(64.0)
        .px(12.0)
        .gap(8.0)
        .center_y()
        .radius(rune::tok::radius::MD)
        .fill(if selected {
            t.control_track
        } else {
            rune::Color::TRANSPARENT
        })
        .hover(t.hover)
        .focusable(true)
        .on_press(move |s: &mut Dictionary| s.selected = Some(id.clone()))
        .child(labels)
        .child(
            IconButton::new(&PENCIL)
                .label("Edit term")
                .disabled(true)
                .build(&k)
                .key("pencil"),
        )
        .child(menu)
        .children(overlays)
}
pub fn view(s: &Dictionary, cx: &mut Cx<Dictionary>) -> El {
    let dark = cx.system_dark();
    let k = Kit::neutral(dark);
    let t = rune::tok::theme(dark);
    let mut content = col().w_full().gap(8.0);
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
            .on_toggle(move |s: &mut Dictionary| s.expanded[group] = !s.expanded[group])
            .build(&k)
            .key(format!("group-{group}"));
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
                        move |_: &Dictionary, i| format!("term-{group}-{}", keys[i]).into(),
                        move |s: &Dictionary, i| term_row(s, group, indices[i], dark),
                    ),
            );
        }
    }
    let body = col()
        .key("body")
        .w_full()
        .grow(1.0)
        .min_h(0.0)
        .padding(24.0)
        .gap(16.0)
        .child(
            text("Dictionary")
                .font(rune::tok::type_::TITLE)
                .color(t.text),
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
                        .height(36.0)
                        .leading_icon(&rune_kit::glyphs::SEARCH)
                        .on_edit(|s: &mut Dictionary| &mut s.search)
                        .on_change(|_: &mut Dictionary, tx| {
                            tx.scroll_to_instant("viewport", 0.0, 0.0)
                        })
                        .build(&k)
                        .key("search")
                        .grow(1.0),
                )
                .child(
                    Button::new("Add term")
                        .disabled(true)
                        .build(&k)
                        .key("add")
                        .h(36.0),
                ),
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
                .child(content),
        );
    col()
        .key("dictionary")
        .w_full()
        .h_full()
        .fill(t.bg)
        .child(body)
        .child(
            el().key("bottom-edge")
                .w_full()
                .h(8.0)
                .role("separator")
                .label("Resize Dictionary height")
                .cursor(rune::Cursor::ResizeRow)
                .on_drag(|s: &mut Dictionary, d: &mut Drag, tx| match d.phase {
                    Phase::Down => d.data = s.observed_height.get(),
                    Phase::Move => {
                        s.height = clamp_height(d.data + d.dy, s.screen);
                        tx.resize_window_instant((s.observed_width.get(), s.height));
                    }
                    Phase::Up => {
                        s.persist(s.height);
                    }
                }),
        )
}
