use rune::*;
use voicebar_rune::band::*;
fn arg(name: &str) -> Option<String> {
    let args: Vec<_> = std::env::args().collect();
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}
fn number(name: &str, default: f32) -> f32 {
    arg(name)
        .map(|s| s.parse().expect("numeric option"))
        .unwrap_or(default)
}
fn initial() -> Band {
    let fail = |message: String| -> ! {
        eprintln!("band: {message}");
        std::process::exit(2)
    };
    let path = arg("--replay").unwrap_or_else(|| fail("requires --replay FILE".into()));
    let source = std::fs::read_to_string(path).unwrap_or_else(|e| fail(e.to_string()));
    let replay = Replay::parse(&source).unwrap_or_else(|e| fail(e));
    let mut state = Band::new(
        replay,
        number("--notch-width", screen_geometry().1).max(0.),
        std::env::args().any(|s| s == "--reduce-motion"),
    );
    state.safe_top = number("--safe-top", screen_geometry().2).max(0.);
    state.system_motion = !headless();
    state.keep_regions = std::env::var("VOICELAYER_RUNE_KEEP_REGIONS").as_deref() == Ok("1");
    state
}
fn headless() -> bool {
    std::env::args()
        .any(|s| ["--snap", "--tree", "--out", "--trace", "--frames"].contains(&s.as_str()))
}
fn main() {
    let s = initial();
    let size = (s.width(), HEIGHT);
    let spec = AppSpec {
        poll: Some(poll),
        ..AppSpec::new("VoiceBar · Band replay", size, initial, view)
    };
    if headless() {
        App::new(spec)
            .window_options(WindowOptions {
                transparent: true,
                borderless: true,
                ..Default::default()
            })
            .run();
        return;
    }
    let mut app = App::new(spec).accessory().windowless();
    let overlay = app.overlay(
        OverlaySpec::new("VoiceBar · Band replay", size, view)
            .options(OverlayOptions {
                placement: Some(OverlayPlacement::Rect {
                    x: (screen_geometry().0 - size.0) / 2.,
                    y: number("--y-offset", 0.),
                    width: size.0,
                    height: size.1,
                }),
                input: OverlayInput::Regions,
                keys: KeyPolicy::None,
                ..Default::default()
            })
            .macos_level(25),
        s,
    );
    let handle = overlay.clone();
    overlay.update(move |s, _| s.overlay = Some(handle));
    if !initial().keep_regions {
        overlay.set_input(OverlayInput::None);
    }
    overlay.show();
    rune::run_windows_with(RunOptions { accessory: true }, move |_| {
        vec![WindowSpec::from_app("host", app).boxed()]
    });
}
#[cfg(target_os = "macos")]
fn screen_geometry() -> (f32, f32, f32) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSScreen;
    let Some(mtm) = MainThreadMarker::new() else {
        return (1512., 0., 0.);
    };
    let Some(screen) = NSScreen::mainScreen(mtm) else {
        return (1512., 0., 0.);
    };
    let frame = screen.frame();
    let notch = if screen.safeAreaInsets().top > 0. {
        let l = screen.auxiliaryTopLeftArea();
        let r = screen.auxiliaryTopRightArea();
        (r.origin.x - l.origin.x - l.size.width).max(0.) as f32
    } else {
        0.
    };
    (
        frame.size.width as f32,
        notch,
        screen.safeAreaInsets().top as f32,
    )
}
#[cfg(not(target_os = "macos"))]
fn screen_geometry() -> (f32, f32, f32) {
    (1512., 0., 0.)
}
