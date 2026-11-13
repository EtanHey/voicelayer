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
    let replay = if arg("--socket").is_some() {
        if arg("--replay").is_some() {
            fail("choose --socket or --replay".into());
        }
        Replay(vec![])
    } else {
        let path = arg("--replay")
            .unwrap_or_else(|| fail("requires --replay FILE or --socket PATH".into()));
        let source = std::fs::read_to_string(path).unwrap_or_else(|e| fail(e.to_string()));
        Replay::parse(&source).unwrap_or_else(|e| fail(e))
    };
    let mut state = Band::new(
        replay,
        number("--notch-width", screen_geometry().1).max(0.),
        std::env::args().any(|s| s == "--reduce-motion"),
    );
    state.live = arg("--socket").is_some();
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
    // Headless receiving mode for the isolated release CPU probe. No window/GPU.
    if std::env::args().any(|s| s == "--headless-live") {
        let path = arg("--socket").expect("--headless-live requires --socket PATH");
        let (tx, rx) = std::sync::mpsc::sync_channel(64);
        let _client = voicebar_rune::socket::Client::start(path.into(), move |m| {
            let _ = tx.send(m);
        });
        let mut state = Band::new(Replay(vec![]), 185., false);
        let start = std::time::Instant::now();
        receive_headless(rx, &mut state, start);
        return;
    }
    let s = initial();
    if s.live && headless() {
        eprintln!("band: --socket uses native mode or --headless-live, not replay tooling");
        std::process::exit(2);
    }
    let size = (s.width(), HEIGHT);
    let keep_regions = s.keep_regions;
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
    if !keep_regions {
        overlay.set_input(OverlayInput::None);
    }
    let _client = arg("--socket").map(|path| {
        let handle = overlay.clone();
        voicebar_rune::socket::Client::start(path.into(), move |m| {
            handle.update(move |s, tx| {
                s.receive(m, tx.clock());
                tx.wake_at(tx.clock());
            });
        })
    });
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

// Channel closure is terminal in both animated and idle receive modes.
fn receive_headless(
    rx: std::sync::mpsc::Receiver<voicebar_rune::socket::Message>,
    state: &mut Band,
    start: std::time::Instant,
) {
    use std::sync::mpsc::RecvTimeoutError;
    loop {
        let result = if state.input_active() {
            rx.recv_timeout(std::time::Duration::from_millis(16))
        } else {
            rx.recv().map_err(|_| RecvTimeoutError::Disconnected)
        };
        let message = match result {
            Ok(m) => Some(m),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        let now = start.elapsed().as_secs_f64();
        if let Some(m) = message {
            state.receive(m, now);
        }
        state.advance(now);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_worker_channel_exits_idle_and_active_loops() {
        for active in [false, true] {
            let (tx, rx) = std::sync::mpsc::channel();
            drop(tx);
            let mut state = Band::new(Replay(vec![]), 185., false);
            if active {
                state.apply(&serde_json::json!({"type":"state","state":"recording"}), 0.);
            }
            receive_headless(rx, &mut state, std::time::Instant::now());
        }
    }
}
