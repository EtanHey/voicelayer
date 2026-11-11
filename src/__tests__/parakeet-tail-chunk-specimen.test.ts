import { expect, test } from "bun:test";
import { existsSync } from "fs";
import { join } from "path";
import { privateCorpusPaths } from "./setup/private-specimens";
import { expectTailKept } from "./setup/private-text-oracle";

// c8 T1: a 31.7 s press-stopped take whose last words fell in a 3.7 s final
// window that the real decoder heard as nothing. Read-only; real model only.
const SESSION = "2026-11-11T21-27-17-284Z-26f28fcb";
const paths = privateCorpusPaths("parakeet-tail-chunk-specimen");
const python = process.env.VOICELAYER_PARAKEET_PYTHON, model = process.env.VOICELAYER_PARAKEET_MODEL;
const live = process.env.QA_VOICE_GOLDEN_LIVE === "1" && !!python && !!model;
if (paths && !live) console.error("[parakeet-tail-chunk-specimen] SKIPPING real Parakeet: set QA_VOICE_GOLDEN_LIVE=1, VOICELAYER_PARAKEET_PYTHON and VOICELAYER_PARAKEET_MODEL.");
const audio = paths && live ? join(paths.recordings, SESSION, "audio.wav") : null;

test.skipIf(!audio)("real Parakeet keeps the last words of a take stopped mid-speech", async () => {
  expect(existsSync(audio!)).toBe(true);
  const proc = Bun.spawn([python!, "-u", join(import.meta.dir, "..", "parakeet-worker.py"), "--model", model!, "--parent-pid", String(process.pid)], {
    env: { ...process.env, HF_HUB_OFFLINE: "1", PYTHONDONTWRITEBYTECODE: "1" }, stdin: "pipe", stdout: "pipe", stderr: "ignore",
  });
  proc.stdin.write(JSON.stringify({ id: 1, op: "transcribe", audio_path: audio }) + "\n");
  proc.stdin.write(JSON.stringify({ id: 2, op: "shutdown" }) + "\n");
  proc.stdin.end();
  const [stdout, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  expect(code).toBe(0);
  const reply = JSON.parse(stdout.split("\n")[0]!);
  expect(reply.ok).toBe(true);
  expect(reply.complete).toBe(true);
  expect(reply.covered_frames).toBe(reply.input_frames);
  expect(typeof reply.text).toBe("string");
  // Candidate source ended "...this is" with nothing after it. Booleans and
  // counts only: a failure must never print the private transcript.
  expectTailKept(reply.text);
}, 180_000);
