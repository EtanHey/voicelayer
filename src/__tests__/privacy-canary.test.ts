import { describe, expect, it, spyOn } from "bun:test";
import { Database } from "bun:sqlite";
import { randomUUID } from "crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { assertNoCanaryDiagnostics, canaryChildEnv, diagnosticLeaks, streamLeaks } from "./setup/privacy-canary";
import * as outro from "../stt-outro-gate";
import { WhisperServerBackend } from "../stt";

// Capture at the process boundary: console methods, raw stdout/stderr writes,
// native/subprocess output and Bun's runner all reach these pipes. Never print
// captured content on failure (it may itself contain private material).
(process.env.PRIV11_CHILD ? describe.skip : describe)("privacy canary process guard", () => {
  for (const [name, files, pattern] of [
    ["outro", [import.meta.path], "PRIV11 sink"],
    ["capture/archive/retranscribe", ["src/__tests__/input-durability.test.ts"],
      "PRIV11|refuses an archive whose audio|does not write a transcript outside|delivers text without claiming archive finalization|warns and delivers VoiceBar STT|both VoiceBar recording and archive creation fail|labels paired archive failures"],
    ["Ask/selection", ["src/__tests__/privacy-pipeline.test.ts", "src/__tests__/socket-client.test.ts"], "PRIV11"],
  ] as const) {
    it(`keeps ${name} content out of every captured diagnostic`, async () => {
      const nonce = randomUUID();
      const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "privacy-"));
      const privateRoot = join(root, "private");
      const home = join(root, `CANARY-HOME-${nonce}`);
      mkdirSync(privateRoot); mkdirSync(home);
      const tokens = [`CANARY-TXT-${nonce}`, `CANARY-HOME-${nonce}`];
      const env = canaryChildEnv(root, nonce);
      const child = Bun.spawn([process.execPath, "test", ...files, "--test-name-pattern", pattern],
        { env, stdout: "pipe", stderr: "pipe" });
      try {
        const [stdout, stderr, code] = await Promise.all([
          new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
        ]);
        if (process.env.PRIV11_RECEIPTS_DIR) writeFileSync(
          join(process.env.PRIV11_RECEIPTS_DIR, name.replaceAll("/", "-") + ".log"), stdout + stderr);
        assertNoCanaryDiagnostics(root, tokens, stdout, stderr);
        expect(code, `${name}: fixture child failed (output withheld)`).toBe(0);
        expect(/\b[1-9]\d* pass\b/.test(stderr), `${name}: no fixtures ran`).toBe(true);
        if (name === "outro") {
          expect(stderr).toContain("outro gate: dropped at 1.00-2.00s");
          expect(stderr).toContain("outro gate: decision energy-present at 1.00-2.00s");
          expect(stderr).toContain("floor -60.0 dBFS, span -40.0, peak -30.0, speech -20.0");
        }
      } finally { child.kill(); rmSync(root, { recursive: true, force: true }); }
    }, 60_000);
  }

  it("detects canaries written through every resolved preload output root", () => {
    const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "roots-"));
    const env = canaryChildEnv(root, randomUUID());
    try {
      for (const key of ["VOICELAYER_TMP_ROOT", "VOICELAYER_STATE_DIR", "QA_VOICE_THINK_FILE"]) {
        expect(env[key]?.startsWith(root + "/"), `${key} escapes diagnostic scan`).toBe(true);
      }
      const code = `import {TMP_ROOT, STATE_DIR} from './src/paths.ts';
        await Bun.write(TMP_ROOT + '/tmp-probe.log', process.env.PRIV11_TEXT);
        await Bun.write(STATE_DIR + '/state-probe.log', process.env.PRIV11_TEXT);
        await Bun.write(process.env.QA_VOICE_THINK_FILE, process.env.PRIV11_TEXT);`;
      const child = Bun.spawnSync([process.execPath, "--preload", "./src/__tests__/setup/preload.ts", "-e", code], { env });
      expect(child.exitCode).toBe(0);
      expect(diagnosticLeaks(root, [env.PRIV11_TEXT!]).sort()).toEqual(["state-probe.log", "thinking.md", "tmp-probe.log"]);
      expect(() => assertNoCanaryDiagnostics(root, [env.PRIV11_TEXT!])).toThrow("Privacy canary escaped");
    } finally { rmSync(root, { recursive: true, force: true }); }
  });

  it("detects diagnostic files, including SQLite bytes, with narrow exclusions", () => {
    const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "scan-"));
    try {
      mkdirSync(join(root, "private"));
      for (const path of ["private/audio.wav", "polish-shadow.jsonl", "daemon.log", "private/debug.log"])
        writeFileSync(join(root, path), "CANARY-TXT-detector");
      const db = new Database(join(root, "journal.db"));
      db.exec("CREATE TABLE diagnostics (text TEXT)");
      db.query("INSERT INTO diagnostics VALUES (?)").run("CANARY-TXT-detector");
      db.close();
      expect(diagnosticLeaks(root, ["CANARY-TXT-detector"]).sort()).toEqual(["daemon.log", "debug.log", "journal.db"]);
    } finally { rmSync(root, { recursive: true, force: true }); }
  });

  it("detects every console writer and split raw stream writes", () => {
    const token = `CANARY-TXT-${randomUUID()}`;
    for (const writer of ["log", "warn", "error", "info", "debug", "trace", "dir", "table", "assert", "stdout", "stderr"]) {
      const code = writer === "stdout" || writer === "stderr"
        ? `process.${writer}.write(process.env.TOKEN.slice(0, 10)); process.${writer}.write(process.env.TOKEN.slice(10))`
        : writer === "assert" ? "console.assert(false, process.env.TOKEN)" : `console.${writer}(process.env.TOKEN)`;
      const child = Bun.spawnSync([process.execPath, "-e", code], { env: { ...process.env, TOKEN: token } });
      expect(child.exitCode).toBe(0);
      expect(streamLeaks(child.stdout.toString(), child.stderr.toString(), [token]).length, writer).toBeGreaterThan(0);
    }
  });
});

(process.env.PRIV11_CHILD ? describe : describe.skip)("PRIV11 sink", () => {
  for (const reason of ["removed", "energy-present"] as const) {
    for (const chunked of [false, true]) {
      if (!chunked && reason !== "removed") continue; // Single-pass logs removals only.
      it(`${chunked ? "chunked" : "single-pass"} ${reason} retains acoustic metadata`, async () => {
        const text = process.env.PRIV11_TEXT!;
        const path = join(process.env.PRIV11_PRIVATE_ROOT!, "fixture.wav");
        writeFileSync(path, Buffer.alloc(44));
        const backend = new WhisperServerBackend({ isServerAvailable: () => true,
          transcribeViaServer: async () => "Keep the full spoken sentence." });
        const evaluation = { phrase: text, reason, startS: 1, endS: 2,
          floorDbfs: -60, spanDbfs: -40, peakDbfs: -30, speechLevelDbfs: -20 };
        const gate = spyOn(outro, "stripHallucinatedOutro").mockReturnValue({
          text, reason, evaluations: [evaluation], removed: reason === "removed" ? [evaluation] : [],
        });
        const chunks = spyOn(backend as any, "transcribeChunkedLongRecording").mockResolvedValue(
          chunked ? { text, segments: [], segmentsText: text } : null);
        const previous = process.env.VOICELAYER_STT_OUTRO_GATE;
        process.env.VOICELAYER_STT_OUTRO_GATE = "1";
        try { expect((await backend.transcribe(path)).text).toBe(text); }
        finally {
          gate.mockRestore(); chunks.mockRestore();
          if (previous === undefined) delete process.env.VOICELAYER_STT_OUTRO_GATE;
          else process.env.VOICELAYER_STT_OUTRO_GATE = previous;
        }
      });
    }
  }
});
