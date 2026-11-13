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

pub const MAX_LINE: usize = 64 * 1024;
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
                    c.stream = stream.try_clone().ok();
                    drop(c);
                    delay = Duration::from_millis(250);
                    let mut framer = Framer::default();
                    let mut bytes = [0; 8192];
                    loop {
                        match stream.read(&mut bytes) {
                            Ok(0) => break,
                            Ok(n) => framer.push(&bytes[..n], &mut receive),
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(_) => break,
                        }
                    }
                    lock.lock().unwrap().stream = None;
                    receive(Message::Disconnected);
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
#[derive(Default)]
struct Framer {
    pending: Vec<u8>,
    dropping: bool,
}
impl Framer {
    fn push(&mut self, bytes: &[u8], receive: &mut impl FnMut(Message)) {
        for &b in bytes {
            if b == b'\n' {
                if !self.dropping && !self.pending.is_empty() {
                    let event = serde_json::from_slice::<Value>(&self.pending)
                        .ok()
                        .filter(valid);
                    receive(event.map(Message::Event).unwrap_or(Message::Skipped));
                }
                self.pending.clear();
                self.dropping = false;
            } else if !self.dropping {
                if self.pending.len() == MAX_LINE {
                    self.pending.clear();
                    self.dropping = true;
                    receive(Message::Skipped);
                } else {
                    self.pending.push(b);
                }
            }
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
