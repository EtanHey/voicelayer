use voicebar_rune::settings::{self, Settings, snapshot};
fn screen() -> f32 {
    if let Ok(h) = std::env::var("VOICELAYER_RUNE_SCREEN_HEIGHT") {
        if let Ok(h) = h.parse::<f32>() {
            if h.is_finite() && h >= settings::MIN_HEIGHT {
                return h;
            }
        }
    }
    #[cfg(target_os = "macos")]
    if let Some(mtm) = objc2::MainThreadMarker::new() {
        if let Some(s) = objc2_app_kit::NSScreen::mainScreen(mtm) {
            return s.visibleFrame().size.height as f32;
        }
    }
    900.0
}
fn initial() -> Settings {
    let real = std::env::args().any(|a| a == "--real");
    let snap = if real {
        snapshot::read(
            &std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .unwrap_or_default(),
            &std::env::vars().collect(),
        )
    } else {
        snapshot::fixture()
    };
    let path = Some(
        std::env::var_os("VOICELAYER_RUNE_SETTINGS_STATE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| {
                std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../.build.noindex/settings-layout.json")
            }),
    );
    let mut s = Settings::new(snap, screen(), path);
    s.select_tab(
        std::env::var("VOICELAYER_RUNE_SETTINGS_TAB")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
    );
    if real {
        s.dictionary = voicebar_rune::Dictionary::new(vec![], s.screen, None);
        s.history = voicebar_rune::history::History::new(Default::default());
    }
    if std::env::var_os("VOICELAYER_RUNE_SETTINGS_LOCKED").is_some() {
        for lock in &mut s.snapshot.processing_locks {
            *lock = Some("QA_FIXTURE_LOCK".into());
        }
        for lock in &mut s.snapshot.speech_locks {
            *lock = Some("QA_FIXTURE_LOCK".into());
        }
    }
    if std::env::var_os("VOICELAYER_RUNE_SETTINGS_BROKEN").is_some() {
        if let Some(steps) = &mut s.snapshot.setup {
            steps.iter_mut().find(|(name,_)| name == "Microphone").unwrap().1 = false;
        }
    }
    s
}
fn main() {
    let state = initial();
    let height = state.height;
    let screen = state.screen;
    rune::App::new(rune::AppSpec {
        min_size: Some((620.0, settings::MIN_HEIGHT)),
        ..rune::AppSpec::new(
            "VoiceBar · Settings",
            (720.0, height),
            initial,
            settings::view,
        )
    })
    .init(move || state)
    .window_options(rune::WindowOptions {
        max_size: Some((f32::MAX, screen)),
        ..Default::default()
    })
    .run();
}
