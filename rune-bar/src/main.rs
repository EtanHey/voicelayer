use voicebar_rune::*;
#[cfg(target_os = "macos")]
fn screen_height() -> f32 {
    #[repr(C)]
    struct Point {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    struct Size {
        width: f64,
        height: f64,
    }
    #[repr(C)]
    struct Rect {
        origin: Point,
        size: Size,
    }
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGMainDisplayID() -> u32;
        fn CGDisplayBounds(id: u32) -> Rect;
    }
    unsafe { CGDisplayBounds(CGMainDisplayID()).size.height as f32 }
}
#[cfg(not(target_os = "macos"))]
fn screen_height() -> f32 {
    900.0
}
fn screen() -> f32 {
    std::env::var("VOICELAYER_RUNE_SCREEN_HEIGHT")
        .ok()
        .and_then(|v| v.parse::<f32>().ok())
        .filter(|h| h.is_finite() && *h > 0.0)
        .unwrap_or_else(screen_height)
}
fn initial() -> Dictionary {
    let fixture_mode = std::env::var_os("VOICELAYER_RUNE_FIXTURE").is_some();
    Dictionary::new(
        if fixture_mode {
            fixture()
        } else {
            read_entries(&vocabulary_path())
        },
        screen(),
        if fixture_mode {
            None
        } else {
            Some(state_path())
        },
    )
}
fn main() {
    let height = initial().height;
    rune::App::new(rune::AppSpec {
        min_size: Some((420.0, 240.0)),
        ..rune::AppSpec::new("VoiceBar · Dictionary", (WIDTH, height), initial, view)
    })
    .window_options(rune::WindowOptions {
        min_size: Some((420.0, 240.0)),
        max_size: Some((f32::MAX, screen())),
        ..Default::default()
    })
    .on_frame_drawn(|rt| {
        rt.state.observed_width.set(rt.viewport.0);
        rt.state.persist(rt.viewport.1);
    })
    .run();
}
