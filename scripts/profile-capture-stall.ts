/**
 * CPU-profile the real Bun child-pipe capture path after its recorder stalls.
 *
 * Run through the test preload so every path stays inside this worktree and
 * fake-rec.sh is the recorder:
 *   bun --preload ./src/__tests__/setup/preload.ts --cpu-prof \
 *     ./scripts/profile-capture-stall.ts
 *
 * The fixture emits 0.8 seconds of PCM, keeps stdout open without EOF, then
 * writes this isolated process's stop signal from a 10 ms interval. A blocked
 * interval or unconsumed stop signal makes the command fail.
 */

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";

if (
  process.env.VOICELAYER_TEST_ISOLATED?.trim() !== "1" ||
  process.env.VOICELAYER_TEST_FAKE_REC?.trim() !== "1" ||
  process.env.VOICELAYER_TEST_REAL_MIC?.trim() === "1"
) {
  throw new Error(
    "Refusing to profile capture without the isolated fake-rec test preload",
  );
}

process.env.VOICELAYER_TEST_FAKE_REC_BIN = join(
  process.cwd(),
  "src",
  "__tests__",
  "setup",
  "fake-rec-stall.sh",
);

const { STOP_FILE, retainedRecordingFilePath } = await import("../src/paths");
const { recordToBuffer } = await import("../src/input");

const retainedPath = retainedRecordingFilePath();
const expectedPcmBytes = 25 * 1_024;

function retainedPcmBytes(): number {
  if (!existsSync(retainedPath)) return 0;
  const wav = readFileSync(retainedPath);
  if (wav.byteLength < 44) return 0;
  return wav.readUInt32LE(40);
}

async function waitUntil(
  predicate: () => boolean,
  label: string,
  timeoutMs: number,
): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error(`Timed out waiting for ${label}`);
    }
    // Keep the harness itself out of the hot profile while still observing the
    // recorder's transition into its open-without-EOF state.
    await Bun.sleep(10);
  }
}

const recording = recordToBuffer(5_000, "thoughtful", true);
let intervalTicks = 0;
let stopWrittenAt = 0;
let interval: ReturnType<typeof setInterval> | undefined;
const startedAt = Date.now();

try {
  await waitUntil(
    () => retainedPcmBytes() === expectedPcmBytes,
    "fake recorder to emit 0.8 seconds of PCM and stall",
    5_000,
  );

  interval = setInterval(() => {
    intervalTicks += 1;
    if (intervalTicks === 5) {
      stopWrittenAt = Date.now();
      writeFileSync(STOP_FILE, "stop");
    }
  }, 10);

  await waitUntil(
    () => stopWrittenAt > 0 && !existsSync(STOP_FILE),
    "capture loop to consume its stop signal",
    500,
  );
  const stopConsumedAfterMs = Date.now() - stopWrittenAt;
  const captured = await Promise.race([
    recording,
    Bun.sleep(700).then(() => {
      throw new Error("Capture did not settle after consuming the stop signal");
    }),
  ]);
  clearInterval(interval);
  interval = undefined;

  if (stopConsumedAfterMs >= 200) {
    throw new Error(`Stop signal latency was ${stopConsumedAfterMs}ms`);
  }
  if (captured?.byteLength !== expectedPcmBytes) {
    throw new Error(
      `Expected ${expectedPcmBytes} retained PCM bytes, got ${captured?.byteLength ?? 0}`,
    );
  }

  console.log(
    JSON.stringify({
      capturedPcmBytes: captured.byteLength,
      elapsedMs: Date.now() - startedAt,
      intervalTicks,
      stopConsumedAfterMs,
    }),
  );
} finally {
  if (interval) clearInterval(interval);
  if (!existsSync(STOP_FILE)) writeFileSync(STOP_FILE, "stop");
  await recording.catch(() => null);
  try {
    if (existsSync(STOP_FILE)) unlinkSync(STOP_FILE);
  } catch {}
  await Bun.sleep(100);
}
