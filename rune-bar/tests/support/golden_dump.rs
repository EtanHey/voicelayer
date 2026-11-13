use rune::{Env, Runtime};
use std::{
    fmt::Write as _,
    io::Write,
    process::{Command, Stdio},
};
const REPLAYS: &[&str] = &[
    "band",
    "band-fast",
    "band-cancel",
    "band-cancel-transcribing",
    "band-recoverable",
    "band-level-exit",
    "band-late-event",
];
fn digest(bytes: &[u8]) -> String {
    let mut child = Command::new("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(bytes).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout)
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .into()
}
fn dump(name: &str, reduced: bool, mut sample: impl FnMut(&mut Band, f64)) -> String {
    let source = std::fs::read_to_string(format!(
        "{}/docs/replays/{name}.ndjson",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap();
    let mut r = Runtime::new(
        Band::new(Replay::parse(&source).unwrap(), 185., reduced),
        view,
        (425., HEIGHT),
        Env::new(true, 2.),
    );
    let mut output = String::new();
    for frame in 0..=660 {
        let t = frame as f64 / 60.;
        r.update(|s, tx| {
            sample(s, t);
            tx.instant();
        });
        r.frame(0.);
        writeln!(
            output,
            "{frame} {:?} {} {:?}",
            r.state.mode,
            r.state.timer(),
            r.elements()
        )
        .unwrap();
    }
    digest(output.as_bytes())
}
