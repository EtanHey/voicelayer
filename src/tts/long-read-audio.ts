import { unlinkSync, writeFileSync } from "fs";
import type { PlayedChunk } from "./long-read";

/** Run only the owned child; cancellation never kills another daemon's process. */
export async function runAudioCommand(argv: string[], signal?: AbortSignal): Promise<void> {
  signal?.throwIfAborted();
  const proc = Bun.spawn(argv, { stdout: "ignore", stderr: "ignore" });
  let escalation: ReturnType<typeof setTimeout> | undefined;
  const kill = () => {
    try { proc.kill("SIGTERM"); } catch {}
    clearTimeout(escalation);
    escalation = setTimeout(() => { try { proc.kill("SIGKILL"); } catch {} }, 250);
  };
  const timeout = setTimeout(kill, 30_000);
  signal?.addEventListener("abort", kill, { once: true });
  try {
    if (signal?.aborted) kill();
    const code = await proc.exited;
    signal?.throwIfAborted();
    if (code !== 0) throw new Error(`Audio conversion failed (${code})`);
  } finally {
    clearTimeout(timeout); clearTimeout(escalation);
    signal?.removeEventListener("abort", kill);
  }
}

/** Re-encode a single replay entry, trimming the interrupted final chunk to actual playback. */
export async function assembleLongReadHistory(played: PlayedChunk[], output: string): Promise<void> {
  const playlist = `${output}.concat.txt`;
  const seconds = played.reduce((total, item) => total + item.playedMs, 0) / 1000;
  // These are daemon-created paths. Quoting also handles apostrophes in TMP_ROOT.
  writeFileSync(playlist, played.map(({ chunk }) => `file '${chunk.audioFile.replace(/'/g, "'\\''")}'`).join("\n"));
  try {
    await runAudioCommand(["ffmpeg", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", playlist,
      "-af", `asetpts=PTS-STARTPTS,atrim=duration=${seconds}`, "-codec:a", "libmp3lame", "-q:a", "2", output]);
  } finally {
    try { unlinkSync(playlist); } catch {}
  }
}
