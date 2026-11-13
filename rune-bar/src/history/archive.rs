//! Read-only scan. Deliberately never creates Swift's speech-history index/cache.
use super::Entry;
use serde_json::Value;
use std::path::{Path, PathBuf};
pub fn root() -> PathBuf {
    // Swift Settings loaders have no environment override.
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join(".local/share/voicelayer/recordings")
}
fn safe_file(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
}
fn read(p: &Path) -> String {
    if safe_file(p) {
        std::fs::read_to_string(p).unwrap_or_default()
    } else {
        String::new()
    }
}
fn directories(p: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(p)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir() && !t.is_symlink()))
        .map(|e| e.path())
        .collect()
}
pub fn load(root: &Path) -> [Vec<Entry>; 3] {
    let mut lists: [Vec<Entry>; 3] = Default::default();
    for day in directories(root) {
        let name = day.file_name().unwrap_or_default().to_string_lossy();
        if name.len() != 10 || name.as_bytes()[4] != b'-' || name.as_bytes()[7] != b'-' {
            continue;
        }
        for dir in directories(&day) {
            let m = serde_json::from_str::<Value>(&read(&dir.join("metadata.json")))
                .unwrap_or(Value::Null);
            let id = dir
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let source = m["source"].as_str().unwrap_or("");
            let category = match source {
                "voice_ask" => 1,
                "speak" => 2,
                _ => 0,
            };
            if category == 0 && !safe_file(&dir.join("audio.wav")) {
                continue;
            }
            if category == 2 && (m["schema_version"] != 1 || m["id"].as_str() != Some(&id)) {
                continue;
            }
            let transcript = read(&dir.join("voicelayer-transcript.txt"));
            let body = match category {
                1 => transcript,
                2 => {
                    if let Some(parts) = m["speech"]["generated"].as_array() {
                        let mut parts = parts.iter().collect::<Vec<_>>();
                        parts.sort_by_key(|v| v["index"].as_i64().unwrap_or(0));
                        parts
                            .iter()
                            .filter_map(|v| v["text"].as_str())
                            .collect::<Vec<_>>()
                            .join(" ")
                    } else {
                        read(&dir.join("spoken.txt"))
                    }
                }
                _ => transcript,
            };
            let duration = if category == 2 {
                m.pointer("/lifecycle/summary/generated_audio_ms")
                    .and_then(Value::as_f64)
                    .or_else(|| m.pointer("/speech/played_ms").and_then(Value::as_f64))
                    .or_else(|| m.pointer("/audio/duration_ms").and_then(Value::as_f64))
                    .or_else(|| {
                        m["artifacts"]
                            .as_array()?
                            .iter()
                            .find(|v| v["role"] == "playback_ready")
                            .and_then(|v| v["duration_ms"].as_f64())
                    })
            } else {
                m["duration_ms"].as_f64()
            };
            lists[category].push(Entry {
                id,
                body: if body.trim().is_empty() {
                    missing_label(&m)
                } else {
                    body.trim().into()
                },
                secondary: if category == 1 {
                    read(&dir.join("agent-transcript.txt")).trim().into()
                } else {
                    String::new()
                },
                status: if category == 2 {
                    m.pointer("/lifecycle/summary/error_code")
                        .and_then(Value::as_str)
                        .or_else(|| m.pointer("/speech/state").and_then(Value::as_str))
                        .or_else(|| m["status"].as_str())
                        .filter(|v| *v != "completed")
                        .unwrap_or("")
                        .into()
                } else {
                    String::new()
                },
                created: m["created_at"].as_str().unwrap_or(&name).into(),
                duration_ms: duration
                    .filter(|n| n.is_finite() && *n >= 0.0)
                    .map(|n| n as u64),
            });
        }
    }
    for list in &mut lists {
        list.sort_by(|a, b| b.created.cmp(&a.created).then(b.id.cmp(&a.id)));
    }
    lists
}

fn missing_label(m: &Value) -> String {
    match m["not_transcribed_reason"].as_str().unwrap_or("") {
        "silent-input" => m["input_dbfs"]
            .as_f64()
            .map(|v| format!("Not transcribed: the microphone sent only silence ({v:.1} dBFS)"))
            .unwrap_or("Not transcribed: the microphone sent only silence".into()),
        "no-speech" | "vad-no-speech" => "Not transcribed: no speech detected".into(),
        "too-short" => "Not transcribed: too short to transcribe".into(),
        "too-quiet" => "Not transcribed: too quiet to transcribe".into(),
        "empty-transcript" => "Transcribed, but no words were recognized".into(),
        "recording-failed" => "Recording failed; no audio was captured".into(),
        "transcription-failed" => m["not_transcribed_detail"]
            .as_str()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(|v| format!("Transcription failed: {v}"))
            .unwrap_or("Transcription failed".into()),
        _ => "No text stored".into(),
    }
}
