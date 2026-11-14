//! Read-only backend feed contract. Unknown runtime values stay absent.
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::Path};
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct SettingsSnapshot {
    /// Monotonic settings revision supplied by the app feed (zero until connected).
    pub revision: u64,
    /// Daemon polish mode: off/on from the store; shadow is environment-only.
    pub polish: Option<Polish>,
    /// WhisperPerformanceStore's effective environment lock, if valid.
    pub effort_lock: Option<String>,
    /// SpeechControlsState's threshold environment lock.
    pub threshold_lock: Option<String>,
    /// SpeechSettingsView's allowed rate bounds and increment, supplied by the app.
    pub rate_min: Option<i32>,
    /// SpeechSettingsView maximum permitted rate, supplied by the app.
    pub rate_max: Option<i32>,
    /// SpeechSettingsView rate increment, supplied by the app.
    pub rate_step: Option<i32>,
    /// PermissionHealthMonitor: microphone, accessibility, input monitoring, listener.
    pub setup: Option<Vec<(String, bool)>>,
    /// HotkeyManager's current dictation binding (UserDefaults plus runtime remapping).
    pub dictation_key: Option<String>,
    /// HotkeyManager F5 helper probe; false means the inline repair is needed.
    pub f5_helper: Option<bool>,
    /// VoiceState's visibility deadline, held by the running app.
    pub visible: Option<bool>,
    /// MicrophonePriorityStore resolved against currently connected CoreAudio devices.
    pub microphones: Option<Vec<String>>,
    /// MicrophonePriorityStore's resolved default device name.
    pub default_microphone: Option<String>,
    /// VoiceState's latest dictation age, without transcript text.
    pub last_age: Option<String>,
    /// VoiceState's latest dictation duration, without transcript text.
    pub last_length: Option<String>,
    /// Recognizer runtime's model label and downloaded model byte size.
    pub recognizer: Option<String>,
    /// Recognizer runtime's resident-model state.
    pub resident: Option<bool>,
    /// Runtime status reports configured/active model; file stores effort only.
    pub configured_model: Option<String>,
    /// Runtime recognizer status's active model.
    pub active_model: Option<String>,
    /// whisper-performance.json effort, overridden by QA_VOICE_WHISPER_PERFORMANCE_EFFORT.
    pub configured_effort: Option<String>,
    /// Recognizer runtime's active effort; never inferred from configured effort.
    pub active_effort: Option<String>,
    /// processing-settings.json model_polish, outro_gate, smart_chunks; env wins.
    pub processing: [Option<bool>; 3],
    /// ProcessingSettingsStore's environment source for each of those three controls.
    pub processing_locks: [Option<String>; 3],
    /// SpeechControlsState's effective short/long voice (tts-settings and runtime env).
    pub voices: [Option<String>; 2],
    /// SpeechControlsState's effective short/long rate.
    pub rates: [Option<String>; 2],
    /// SpeechControlsState's available clone profiles, from voices/*/profile.yaml.
    pub available_voices: Vec<String>,
    /// SpeechControlsState's environment lock reasons: short voice/rate, long voice/rate.
    pub speech_locks: [Option<String>; 4],
    /// SpeechControlsState's effective short_limit_chars (tts-settings.json).
    pub threshold: Option<u64>,
    /// SpeechControlsState's clone daemon health, only available from the app.
    pub clone_status: Option<String>,
    /// Bundle version from the running app's Info.plist.
    pub version: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Polish {
    Off,
    Shadow,
    On,
}
impl Polish {
    pub fn name(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Shadow => "shadow",
            Self::On => "on",
        }
    }
}
pub fn fixture() -> SettingsSnapshot {
    serde_json::from_str(include_str!("../../fixtures/settings.json")).expect("neutral snapshot")
}
fn json(path: &Path) -> serde_json::Value {
    // Never follow a symlink into a different store or secret file.
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file()) {
        std::fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    } else {
        serde_json::Value::Null
    }
}
pub fn read(home: &Path, env: &BTreeMap<String, String>) -> SettingsSnapshot {
    let state = home.join(".local/state/voicelayer");
    let processing_path = state.join("processing-settings.json");
    let p = if std::fs::symlink_metadata(&processing_path)
        .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
    {
        serde_json::json!({})
    } else {
        json(&processing_path)
    };
    let w = json(&state.join("whisper-performance.json"));
    let mut s = SettingsSnapshot::default();
    for (i, (key, var)) in [
        ("model_polish", "QA_VOICE_STT_POLISH"),
        ("outro_gate", "VOICELAYER_STT_OUTRO_GATE"),
        ("smart_chunks", "VOICELAYER_STT_SMART_CHUNKS"),
    ]
    .iter()
    .enumerate()
    {
        s.processing[i] = if !p.is_object() {
            None
        } else if i == 0 {
            s.polish = match p.get(*key) {
                None => Some(Polish::On),
                Some(raw) => match raw.as_str() {
                    Some("off") => Some(Polish::Off),
                    Some("on") => Some(Polish::On),
                    _ => None,
                },
            };
            s.polish.map(|p| p == Polish::On)
        } else {
            match p.get(*key) {
                None => Some(i == 1),
                Some(raw) => raw.as_bool(),
            }
        };
        if let Some(v) = env.get(*var) {
            s.processing_locks[i] = Some((*var).into());
            // These controls use the daemon's opt-in/out semantics.
            let raw = v.trim().to_lowercase();
            if i == 0 {
                s.polish = Some(match raw.as_str() {
                    "off" => Polish::Off,
                    "shadow" => Polish::Shadow,
                    _ => Polish::On,
                });
            }
            s.processing[i] = Some(match i {
                0 => raw != "off",
                1 => ["", "1", "true", "on", "yes"].contains(&raw.as_str()),
                _ => ["1", "true", "on", "yes"].contains(&raw.as_str()),
            });
        }
    }
    let effort_var = "QA_VOICE_WHISPER_PERFORMANCE_EFFORT";
    let valid = |v: &String| ["fast", "balanced", "accurate"].contains(&v.as_str());
    let override_effort = env
        .get(effort_var)
        .map(|v| v.trim().to_lowercase())
        .filter(valid);
    s.effort_lock = override_effort.as_ref().map(|_| effort_var.into());
    s.configured_effort = Some(
        override_effort
            .or(w["effort"]
                .as_str()
                .map(|v| v.trim().to_lowercase())
                .filter(valid))
            .unwrap_or_else(|| "accurate".into())
            .into(),
    );
    let voices = home.join(".voicelayer/voices");
    if std::fs::symlink_metadata(&voices).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()) {
        if let Ok(entries) = std::fs::read_dir(voices) {
            for e in entries.flatten() {
                if e.file_type().is_ok_and(|t| t.is_dir())
                    && std::fs::symlink_metadata(e.path().join("profile.yaml"))
                        .is_ok_and(|m| m.file_type().is_file())
                {
                    if let Some(name) = e.file_name().to_str() {
                        s.available_voices.push(name.into());
                    }
                }
            }
        }
    }
    s.available_voices.sort();
    // Profile files name available clones, not selected voices, rates, or daemon health.
    s
}
