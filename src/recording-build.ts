/** Capture identity comes only from the running VoiceBar's bundle handoff, never this checkout. */
export interface RecordingAppBuild {
  version: string | null;
  git_commit: string | null;
  build_time_utc: string | null;
  source: "VoiceBar.Info.plist" | null;
}
export function recordingAppBuild(env = process.env): RecordingAppBuild {
  const known = env.VOICEBAR_BUILD_SOURCE === "VoiceBar.Info.plist";
  const value = (key: string) => {
    const text = known ? env[key]?.trim() : null;
    return text && text !== "unknown" ? text : null;
  };
  const sha = value("VOICEBAR_GIT_COMMIT"), time = value("VOICEBAR_BUILD_TIME_UTC");
  return { version: value("VOICEBAR_VERSION"), git_commit: sha && /^[a-f0-9]{40}$/i.test(sha) ? sha : null,
    build_time_utc: time && Number.isFinite(Date.parse(time)) ? time : null,
    source: known ? "VoiceBar.Info.plist" : null };
}
/** A legacy capture is unknown; a retry must never claim today's build captured it. */
export function tagRetranscription(metadata: Record<string, unknown>): void {
  metadata.app_build ??= recordingAppBuild({});
  metadata.retranscribed_by = recordingAppBuild();
}
