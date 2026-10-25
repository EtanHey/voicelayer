import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { recoverSpeakArchive, updateSpeakLifecycle, type SpeakLifecycle } from "../speak-archive-store";

const request: SpeakReceiptRequest = {
  input: " \tBun שלום🙂 e\u0301 fu… no, full\r\n ", request_id: "synthetic-rate-boundary",
  request_source: "voice_speak", connection: "stdio", format: null, blocking: false,
  requested: { mode: "announce", profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
};
const lifecycle: SpeakLifecycle = {
  status: "preparing", generation_id: null,
  timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
  summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [],
};
let root: string, previous: string;

describe("raw requested rate admission (real isolated creator and store)", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        relative(resolve(run), resolve(redirected)).startsWith("..") || resolve(run) === resolve(redirected)) {
      throw new Error("canonical isolated preload required");
    }
    previous = redirected;
    root = fs.mkdtempSync(join(redirected, "speak-rate-boundary-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    if (previous) process.env.QA_VOICE_RECORDINGS_DIR = previous;
    if (root) fs.rmSync(root, { recursive: true, force: true });
  });

  for (const [name, rate_raw] of [
    ["high surrogate", "\ud800"], ["low surrogate", "\udc00"], ["embedded surrogate", "+0\ud800%"],
  ] as const) {
    it(`rejects ${name} before any entry or day allocation`, () => {
      const result = createSpeakReceipt({ ...request, requested: { ...request.requested, rate_raw } });
      expect(result).toEqual({ kind: "failed", stage: "validate", code: "INVALID_INPUT", partial: null });
      expect(fs.readdirSync(root)).toEqual([]);
    });
  }

  for (const [name, rate_raw] of [
    ["empty", ""], ["Unicode", " \tשלום🙂 e\u0301\r\n "], ["spelling", "+020%"], ["omitted", undefined],
  ] as const) {
    it(`preserves ${name} through creation, lifecycle updates and recovery`, () => {
      const requested = { ...request.requested, ...(rate_raw !== undefined ? { rate_raw } : {}) };
      const result = createSpeakReceipt({ ...request, requested });
      expect(result.kind).toBe("created");
      if (result.kind !== "created") throw new Error("synthetic receipt creation failed");
      const context = result.context;
      expect(context.metadata.requested).toEqual(requested);
      expect(updateSpeakLifecycle(context, lifecycle).kind).toBe("stored");
      expect(updateSpeakLifecycle(context, { ...lifecycle, status: "stopped" }).kind).toBe("stored");
      const recovered = recoverSpeakArchive(context.id);
      expect(recovered.kind).toBe("stored");
      if (recovered.kind !== "stored") throw new Error("synthetic receipt recovery failed");
      expect(recovered.metadata.requested).toEqual(requested);
      expect(recovered.metadata.status).toBe("stopped");
      const metadata = JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"));
      expect(metadata.requested).toEqual(requested);
      if (rate_raw === undefined) expect(metadata.requested).not.toHaveProperty("rate_raw");
      else expect(metadata.requested.rate_raw).toBe(rate_raw);
      expect(fs.readFileSync(join(context.path, "input.txt"))).toEqual(Buffer.from(request.input));
    });
  }
});
