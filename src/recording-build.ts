/** Capture identity comes only from the running VoiceBar's bundle handoff, never this checkout. */
export interface RecordingAppBuild {
  version: string | null;
  git_commit: string | null;
  git_describe: string | null;
  daemon_source: "bundled" | "checkout" | "homebrew" | "unknown";
  build_time_utc: string | null;
  source: "VoiceBar.Info.plist" | null;
}
export function recordingAppBuild(env = process.env): RecordingAppBuild {
  const known = env.VOICEBAR_BUILD_SOURCE === "VoiceBar.Info.plist" && /^[a-f0-9]{40}$/i.test(env.VOICEBAR_GIT_COMMIT ?? "");
  const value = (key: string) => {
    const text = known ? env[key]?.trim() : null;
    return text && text !== "unknown" ? text : null;
  };
  const sha = value("VOICEBAR_GIT_COMMIT"), time = value("VOICEBAR_BUILD_TIME_UTC");
  return { version: value("VOICEBAR_VERSION"), git_commit: sha && /^[a-f0-9]{40}$/i.test(sha) ? sha : null,
    git_describe: value("VOICEBAR_GIT_DESCRIBE"),
    daemon_source: ["bundled", "checkout", "homebrew"].includes(env.VOICEBAR_DAEMON_SOURCE ?? "")
      ? env.VOICEBAR_DAEMON_SOURCE as RecordingAppBuild["daemon_source"] : "unknown",
    build_time_utc: time && Number.isFinite(Date.parse(time)) ? time : null,
    source: known ? "VoiceBar.Info.plist" : null };
}
/** Preserve capture identity; only an earlier successful transcript makes this a re-transcription. */
export function tagTranscription(metadata: Record<string, unknown>, previous = metadata): void {
  const retry = previous.transcription_status === "transcribed" || Number(previous.voicelayer_transcript_chars) > 0;
  metadata.app_build ??= recordingAppBuild({});
  metadata[retry ? "retranscribed_by" : "transcribed_by"] = recordingAppBuild();
}
