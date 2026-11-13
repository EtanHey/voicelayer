//! Read-only Unix transport. No default path, registration, writes, or keepalive.
use serde_json::Value;
use std::{
    io::{self, Read},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::{Arc, Condvar, Mutex},
    thread::{self, JoinHandle},
    time::Duration,
};

pub const MAX_LINE: usize = 4 * 1024 * 1024;
#[derive(Debug)]
pub enum Message {
    Event(Value),
    Skipped,
    Disconnected,
    Retrying(Duration),
}

#[derive(Default)]
struct Control {
    stopped: bool,
    stream: Option<UnixStream>,
}
pub struct Client {
    control: Arc<(Mutex<Control>, Condvar)>,
    worker: Option<JoinHandle<()>>,
}
impl Client {
    pub fn start(path: PathBuf, mut receive: impl FnMut(Message) + Send + 'static) -> Self {
        let control = Arc::new((Mutex::new(Control::default()), Condvar::new()));
        let shared = control.clone();
        let worker = thread::spawn(move || {
            let (lock, wake) = &*shared;
            let mut delay = Duration::from_millis(250);
            loop {
                if lock.lock().unwrap().stopped {
                    break;
                }
                if let Ok(mut stream) = UnixStream::connect(&path) {
                    let mut c = lock.lock().unwrap();
                    if c.stopped {
                        break;
                    }
                    // A shutdown handle is mandatory before entering a blocking read.
                    if !retain_shutdown_handle(&mut c, || stream.try_clone()) {
                        drop(c);
                    } else {
                        drop(c);
                        let mut framer = Framer::default();
                        let mut bytes = [0; 8192];
                        loop {
                            match stream.read(&mut bytes) {
                                Ok(0) => break,
                                Ok(n) => framer.push(&bytes[..n], &mut |message| {
                                    if matches!(message, Message::Event(_)) {
                                        delay = Duration::from_millis(250);
                                    }
                                    receive(message);
                                }),
                                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                                Err(_) => break,
                            }
                        }
                        framer.finish(&mut receive, &mut log_skipped);
                        lock.lock().unwrap().stream = None;
                        receive(Message::Disconnected);
                    }
                }
                if lock.lock().unwrap().stopped {
                    break;
                }
                receive(Message::Retrying(delay));
                let c = lock.lock().unwrap();
                let (c, _) = wake.wait_timeout_while(c, delay, |c| !c.stopped).unwrap();
                if c.stopped {
                    break;
                }
                delay = (delay * 2).min(Duration::from_secs(5));
            }
        });
        Self {
            control,
            worker: Some(worker),
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        let (lock, wake) = &*self.control;
        let mut c = lock.lock().unwrap();
        c.stopped = true;
        if let Some(stream) = &c.stream {
            let _ = stream.shutdown(Shutdown::Both);
        }
        wake.notify_all();
        drop(c);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn retain_shutdown_handle(c: &mut Control, clone: impl FnOnce() -> io::Result<UnixStream>) -> bool {
    match clone() {
        Ok(stream) => {
            c.stream = Some(stream);
            true
        }
        Err(_) => false,
    }
}
fn log_skipped(bytes: usize) {
    eprintln!("band: skipped line bytes={bytes}");
}
#[derive(Default)]
struct Framer {
    pending: Vec<u8>,
    bytes: usize,
    dropping: bool,
    logged: bool,
}
impl Framer {
    fn push(&mut self, bytes: &[u8], receive: &mut impl FnMut(Message)) {
        self.push_with_log(bytes, receive, &mut log_skipped);
    }
    fn finish(&mut self, receive: &mut impl FnMut(Message), log: &mut impl FnMut(usize)) {
        if self.dropping {
            receive(Message::Skipped);
            self.log_once(log);
        }
        self.pending.clear();
        self.bytes = 0;
        self.dropping = false;
    }
    fn log_once(&mut self, log: &mut impl FnMut(usize)) {
        if !self.logged {
            log(self.bytes);
            self.logged = true;
        }
    }
    fn push_with_log(
        &mut self,
        bytes: &[u8],
        receive: &mut impl FnMut(Message),
        log: &mut impl FnMut(usize),
    ) {
        for &b in bytes {
            if b == b'\n' {
                if self.dropping {
                    self.finish(receive, log);
                    continue;
                }
                if !self.pending.is_empty() {
                    let event = serde_json::from_slice::<Value>(&self.pending)
                        .ok()
                        .filter(valid);
                    if let Some(event) = event {
                        receive(Message::Event(event));
                    } else {
                        receive(Message::Skipped);
                        self.log_once(log);
                    }
                }
                self.pending.clear();
                self.bytes = 0;
            } else {
                self.bytes = self.bytes.saturating_add(1);
                if !self.dropping {
                    if self.pending.len() == MAX_LINE {
                        self.pending.clear();
                        self.dropping = true;
                    } else {
                        self.pending.push(b);
                    }
                }
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clone_failure_refuses_blocking_read() {
        let mut c = Control::default();
        assert!(!retain_shutdown_handle(&mut c, || Err(io::Error::other(
            "injected"
        ))));
        assert!(c.stream.is_none());
        let (a, _b) = UnixStream::pair().unwrap();
        assert!(retain_shutdown_handle(&mut c, || a.try_clone()));
        assert!(c.stream.is_some());
    }
    #[test]
    fn logs_only_byte_count_once_per_connection_and_bounds_storage() {
        for _connection in 0..2 {
            let mut f = Framer::default();
            let mut messages = vec![];
            let mut counts = vec![];
            for _line in 0..2 {
                f.push_with_log(
                    &vec![b'x'; MAX_LINE + 17],
                    &mut |m| messages.push(m),
                    &mut |n| counts.push(n),
                );
                assert!(f.pending.len() <= MAX_LINE);
                f.push_with_log(b"\n", &mut |m| messages.push(m), &mut |n| counts.push(n));
            }
            assert_eq!(counts, vec![MAX_LINE + 17]);
            assert_eq!(
                messages
                    .iter()
                    .filter(|m| matches!(m, Message::Skipped))
                    .count(),
                2
            );
        }
    }
}
fn valid(v: &Value) -> bool {
    match v["type"].as_str() {
        Some("state") => matches!(
            v["state"].as_str(),
            Some("idle" | "recording" | "transcribing")
        ),
        Some("audio_level") => v["rms"].as_f64().is_some(),
        Some("transcription_status" | "transcription" | "error" | "queue") => true,
        _ => false,
    }
}
