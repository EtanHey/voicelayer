// Test-only executable: never load a model or print prompts/audio/transcripts.
import { appendFileSync } from "node:fs";
const engine = process.env.VOICELAYER_TEST_STT_ENGINE ?? process.argv[2] ?? "whisper";
const record = {
  at: new Date().toISOString(), pid: process.pid, ppid: process.ppid, engine,
  callsite: process.env.VOICELAYER_TEST_STT_CALLSITE ?? "PATH child (see parent test output)",
  denied: true, exitCode: 78,
  // Fixed booleans only: a prompt value shaped like --PRIVATE is still private.
  options: { model: process.argv.includes("-m") || process.argv.includes("--model"),
    input: process.argv.includes("-f") || process.argv.includes("--file"),
    prompt: process.argv.includes("--prompt"), help: process.argv.includes("--help") },
};
const log = process.env.VOICELAYER_TEST_STT_STUB_LOG;
if (!log) throw new Error("STT guard log missing");
appendFileSync(log, JSON.stringify(record) + "\n", { mode: 0o600 });
console.error(`[STT_LIVE_OPT_IN_REQUIRED] ${engine}: real STT disabled; use QA_VOICE_GOLDEN_LIVE=1 explicitly.`);
process.exit(78);
