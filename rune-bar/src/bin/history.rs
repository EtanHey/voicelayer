use voicebar_rune::history::{self, History};
fn initial() -> History {
    let fixture = std::env::var("VOICELAYER_RUNE_FIXTURE").as_deref() == Ok("1");
    let mut state = History::new(if fixture {
        history::fixture()
    } else {
        history::archive::load(&history::archive::root())
    });
    state.select(
        std::env::var("VOICELAYER_RUNE_HISTORY_CATEGORY")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
    );
    state
}
fn main() {
    rune::App::new(rune::AppSpec {
        min_size: Some((420.0, 300.0)),
        on_key: Some(history::key),
        ..rune::AppSpec::new("VoiceBar · History", (720.0, 720.0), initial, history::view)
    })
    .run();
}
