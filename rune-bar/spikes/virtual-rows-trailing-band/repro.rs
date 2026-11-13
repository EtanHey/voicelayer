// Headless only: compare virtual and ordinary rows; never reads a store.
use rune::{Cx, El, GrowthSpec, ScrollSpec, col, row, text};
fn item(i: usize) -> El {
    row()
        .w_full()
        .h(64.0)
        .center_y()
        .child(text(format!("Neutral row {i}")).color(rune::Color::WHITE))
}
fn view(_: &(), _: &mut Cx<()>) -> El {
    let rows = col().key("rows").w_full().growth(GrowthSpec::default());
    let rows = if std::env::var_os("RUNE_REPRO_ORDINARY").is_some() {
        rows.children((0..1000).map(item))
    } else {
        rows.growth(GrowthSpec::default()).virtual_rows(
            1000,
            64.0,
            |_: &(), i| format!("row-{i}").into(),
            |_: &(), i| item(i),
        )
    };
    col()
        .w_full()
        .h_full()
        .fill(rune::Color::BLACK)
        .child(text("Header").h(108.25))
        .child(
            col()
                .key("viewport")
                .w_full()
                .h(499.75)
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .child(col().child(text("Section").h(40.0)).child(rows)),
        )
}
fn main() {
    rune::App::new(rune::AppSpec::new(
        "Trailing band repro",
        (620.0, 640.0),
        || (),
        view,
    ))
    .run();
}
