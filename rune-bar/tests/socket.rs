use rune::{Env, Runtime};
use serde_json::json;
use std::{
    fs,
    io::{Read, Write},
    os::unix::net::UnixListener,
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use voicebar_rune::{
    band::*,
    socket::{Client, Message},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
            ".s{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn socket(&self) -> PathBuf {
        self.0.join("s")
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn rt(s: Band) -> Runtime<Band> {
    Runtime::new(s, view, (425., HEIGHT), Env::new(true, 2.))
}
fn tree(r: &mut Runtime<Band>, t: f64, replay: bool) -> String {
    r.update(|s, tx| {
        if replay {
            s.sample(t);
        } else {
            s.advance(t);
        }
        tx.instant();
    });
    r.frame(0.);
    format!("{:?}", r.elements())
}
#[test]
fn incremental_equals_replay_at_every_frame() {
    for source in [
        include_str!("../docs/replays/band.ndjson"),
        include_str!("../docs/replays/band-fast.ndjson"),
        include_str!("../docs/replays/band-cancel.ndjson"),
        include_str!("../docs/replays/band-cancel-transcribing.ndjson"),
        include_str!("../docs/replays/band-recoverable.ndjson"),
    ] {
        let replay = Replay::parse(source).unwrap();
        let mut a = rt(Band::new(replay.clone(), 185., false));
        let mut b = rt(Band::new(Replay(vec![]), 185., false));
        let mut cursor = 0;
        for frame in 0..=660 {
            let t = frame as f64 / 60.;
            while cursor < replay.0.len() && replay.0[cursor]["t"].as_f64().unwrap() <= t {
                let e = &replay.0[cursor];
                b.state.apply(e, e["t"].as_f64().unwrap());
                cursor += 1;
            }
            assert_eq!(
                tree(&mut a, t, true),
                tree(&mut b, t, false),
                "frame {frame}"
            );
            assert!(b.state.replay.0.is_empty());
        }
    }
}
#[test]
fn garbage_split_lines_and_exact_zero_writes() {
    let temp = Temp::new();
    let listener = UnixListener::bind(temp.socket()).unwrap();
    let (tx, rx) = mpsc::channel();
    let client = Client::start(temp.socket(), move |m| {
        tx.send(m).unwrap();
    });
    let (mut peer, _) = listener.accept().unwrap();
    peer.write_all(b"broken\n").unwrap();
    peer.write_all(&vec![b'x'; 1024 * 1024]).unwrap();
    peer.write_all(b"\n").unwrap();
    peer.write_all(b"{\"type\":\"unknown\"}\n{\"type\":\"state\",\"sta")
        .unwrap();
    peer.write_all(b"te\":\"recording\"}\n").unwrap();
    let mut s = Band::new(Replay(vec![]), 185., false);
    for _ in 0..4 {
        s.receive(rx.recv_timeout(Duration::from_secs(2)).unwrap(), 0.);
    }
    assert_eq!(s.skipped_lines, 3);
    assert_eq!(s.mode, Mode::Recording);
    peer.set_read_timeout(Some(Duration::from_millis(80)))
        .unwrap();
    assert!(
        peer.read(&mut [0; 1]).is_err(),
        "no hello, ping or commands"
    );
    drop(client);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"");
    assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 1);
}
#[test]
fn disconnect_exits_and_reconnect_starts_fresh_take() {
    let temp = Temp::new();
    let listener = UnixListener::bind(temp.socket()).unwrap();
    let (tx, rx) = mpsc::channel();
    let client = Client::start(temp.socket(), move |m| {
        let _ = tx.send(m);
    });
    let (mut peer, _) = listener.accept().unwrap();
    peer.write_all(
        b"{\"type\":\"state\",\"state\":\"recording\"}\n{\"type\":\"audio_level\",\"rms\":0.8}\n",
    )
    .unwrap();
    let mut r = rt(Band::new(Replay(vec![]), 185., false));
    for _ in 0..2 {
        r.state
            .receive(rx.recv_timeout(Duration::from_secs(1)).unwrap(), 0.);
    }
    r.state.advance(10.);
    assert_eq!(r.state.timer(), "0:10");
    drop(peer);
    drop(listener);
    fs::remove_file(temp.socket()).unwrap();
    assert!(matches!(
        rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        Message::Disconnected
    ));
    r.state.disconnect(10.);
    assert!(r.state.exit_from.is_some());
    assert!(r.state.input_active());
    tree(&mut r, 10.16, false);
    assert_eq!(r.state.mode, Mode::Idle);
    assert!(!r.state.input_active());
    assert!(
        !r.elements()
            .iter()
            .any(|e| e.key.as_deref() == Some("signal"))
    );
    assert!(
        matches!(rx.recv_timeout(Duration::from_secs(1)).unwrap(),Message::Retrying(d) if d == Duration::from_millis(250))
    );
    // Server is absent for the next attempt: backoff must double.
    assert!(
        matches!(rx.recv_timeout(Duration::from_secs(1)).unwrap(),Message::Retrying(d) if d == Duration::from_millis(500))
    );
    let listener = UnixListener::bind(temp.socket()).unwrap();
    let (mut peer, _) = listener.accept().unwrap();
    peer.write_all(b"{\"type\":\"state\",\"state\":\"idle\"}\n{\"type\":\"state\",\"state\":\"recording\"}\n{\"type\":\"audio_level\",\"rms\":0.2}\n").unwrap();
    for _ in 0..3 {
        r.state
            .receive(rx.recv_timeout(Duration::from_secs(1)).unwrap(), 11.);
    }
    assert_eq!(r.state.mode, Mode::Recording);
    assert_eq!(r.state.timer(), "0:00");
    assert!(r.state.exit_from.is_none());
    drop(client);
}
#[test]
fn live_normal_take_matches_replay_within_one_frame() {
    let temp = Temp::new();
    let listener = UnixListener::bind(temp.socket()).unwrap();
    let replay = Replay::parse(include_str!("../docs/replays/band.ndjson")).unwrap();
    let (tx, rx) = mpsc::channel();
    let client = Client::start(temp.socket(), move |m| {
        let _ = tx.send((Instant::now(), m));
    });
    let (mut peer, _) = listener.accept().unwrap();
    let start = Instant::now();
    let events = replay.0.clone();
    let server = thread::spawn(move || {
        for mut e in events {
            let t = e["t"].as_f64().unwrap();
            thread::sleep(Duration::from_secs_f64(t).saturating_sub(start.elapsed()));
            e.as_object_mut().unwrap().remove("t");
            writeln!(peer, "{e}").unwrap();
        }
        peer
    });
    let mut live = rt(Band::new(Replay(vec![]), 185., false));
    let mut expected = rt(Band::new(replay.clone(), 185., false));
    let mut observed = Replay(vec![]);
    let mut count = 0;
    for frame in 0..=570 {
        let t = frame as f64 / 60.;
        thread::sleep(Duration::from_secs_f64(t).saturating_sub(start.elapsed()));
        while let Ok((received, m)) = rx.try_recv() {
            let actual = received.duration_since(start).as_secs_f64();
            let Message::Event(mut e) = m else {
                panic!("unexpected transport message");
            };
            let due = replay.0[count]["t"].as_f64().unwrap();
            assert!(
                (actual - due).abs() < 1. / 60.,
                "late event {actual} vs {due}"
            );
            live.state.apply(&e, actual);
            e["t"] = json!(actual);
            observed.0.push(e);
            count += 1;
        }
        let t = start.elapsed().as_secs_f64();
        expected.state.replay = observed.clone();
        assert_eq!(
            tree(&mut live, t, false),
            tree(&mut expected, t, true),
            "frame {frame}"
        );
    }
    assert_eq!(count, replay.0.len());
    drop(server.join().unwrap());
    drop(client);
}
#[test]
fn binary_uses_only_explicit_socket_and_writes_no_files() {
    let temp = Temp::new();
    let home = temp.0.join("home");
    fs::create_dir(&home).unwrap();
    let listener = UnixListener::bind(temp.socket()).unwrap();
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_band"))
        .args(["--headless-live", "--socket"])
        .arg(temp.socket())
        .env("HOME", &home)
        .spawn()
        .unwrap();
    let (mut peer, _) = listener.accept().unwrap();
    peer.write_all(b"{\"type\":\"state\",\"state\":\"idle\"}\n")
        .unwrap();
    let output = std::process::Command::new("/usr/sbin/lsof")
        .args(["-a", "-p", &child.id().to_string(), "-U", "-Fn"])
        .output()
        .unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    let output = String::from_utf8(output.stdout).unwrap();
    assert_eq!(
        output
            .lines()
            .filter(|l| l.starts_with('n'))
            .collect::<std::collections::HashSet<_>>()
            .len(),
        1,
        "{output}"
    );
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).unwrap();
    assert!(bytes.is_empty());
    assert_eq!(fs::read_dir(home).unwrap().count(), 0);
    assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 2);
    let result = std::process::Command::new(env!("CARGO_BIN_EXE_band"))
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(2));
}

#[test]
fn absent_server_backoff_doubles_and_caps_at_five_seconds() {
    let temp = Temp::new();
    let (tx, rx) = mpsc::channel();
    let client = Client::start(temp.socket(), move |m| {
        let _ = tx.send(m);
    });
    let mut previous = Instant::now();
    let mut previous_delay = Duration::ZERO;
    for millis in [250, 500, 1000, 2000, 4000, 5000, 5000] {
        let message = rx.recv_timeout(Duration::from_secs(6)).unwrap();
        assert!(previous.elapsed() >= previous_delay);
        assert!(matches!(message, Message::Retrying(d) if d == Duration::from_millis(millis)));
        previous = Instant::now();
        previous_delay = Duration::from_millis(millis).saturating_sub(Duration::from_millis(10));
    }
    let stop = Instant::now();
    drop(client);
    assert!(
        stop.elapsed() < Duration::from_millis(250),
        "drop interrupts backoff"
    );
    assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 0);
}
