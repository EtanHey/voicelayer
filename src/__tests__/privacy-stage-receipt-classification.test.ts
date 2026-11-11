import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash, randomUUID } from "crypto";
import { chmodSync, linkSync, mkdirSync, mkdtempSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { diagnosticLeaks, streamLeaks } from "./setup/privacy-canary";

const token = "CANARY-TXT-private-stages";
const id = "2026-11-10T12-00-00-000Z-1234abcd";
let root: string, privateRoot: string, recordingsRoot: string, path: string, audioPath: string;
let receipt: any;
const scan = (configuredRoot: string | undefined = recordingsRoot) => diagnosticLeaks(root, [token], privateRoot, configuredRoot);
const save = () => writeFileSync(path, JSON.stringify(receipt), { mode: 0o600 });

beforeEach(() => {
  root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "stage-classifier-"));
  privateRoot = join(root, "private");
  recordingsRoot = join(privateRoot, "recordings");
  audioPath = join(recordingsRoot, id.slice(0, 10), id, "audio.wav");
  path = join(privateRoot, "transcription-stages", id.slice(0, 10), id, `stt-stages-${randomUUID()}.json`);
  mkdirSync(dirname(audioPath), { recursive: true, mode: 0o700 });
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const audio = Buffer.from("synthetic archived audio");
  writeFileSync(audioPath, audio, { mode: 0o600 });
  receipt = { schema_version: 1, attempt_id: path.slice(path.lastIndexOf("stt-stages-") + 11, -5),
    created_at: "2026-11-10T12:00:00.000Z", audio_sha256: createHash("sha256").update(audio).digest("hex"),
    raw_stage: "backend-return", delivery_observed: false, complete: true, polish_status: "skipped",
    stages: { raw: token, after_rules: token, after_polish: token, delivered: token } };
  save();
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

test("classifies only a private audio-bound stage receipt, including its pre-await state", () => {
  expect(scan()).toEqual([]);
  receipt.complete = false; receipt.polish_status = null;
  receipt.stages.after_polish = null; receipt.stages.delivered = null; save();
  expect(scan()).toEqual([]);
  expect(diagnosticLeaks(root, [token], privateRoot)).toEqual([path.split("/").at(-1)!]);
});
test("still detects adjacent logs and both captured streams", () => {
  writeFileSync(join(dirname(path), "debug.log"), token);
  expect(scan()).toEqual(["debug.log"]);
  expect(streamLeaks(token, token, [token])).toEqual(["stdout", "stderr"]);
});
for (const defect of ["schema", "attempt", "hash", "source", "delivery", "state", "extra"] as const) {
  test(`scans a stage-looking diagnostic with invalid ${defect}`, () => {
    if (defect === "schema") receipt.schema_version = 2;
    if (defect === "attempt") receipt.attempt_id = randomUUID();
    if (defect === "hash") receipt.audio_sha256 = "0".repeat(64);
    if (defect === "source") receipt.raw_stage = "diagnostic";
    if (defect === "delivery") receipt.delivery_observed = true;
    if (defect === "state") receipt.complete = false;
    if (defect === "extra") receipt.debug = token;
    save(); expect(scan()).toContain(path.split("/").at(-1)!);
  });
}
for (const component of ["private", "stages", "day", "entry", "receipt", "audio"] as const) {
  test(`scans insecure ${component} permissions`, () => {
    const target = component === "private" ? privateRoot : component === "stages" ? join(privateRoot, "transcription-stages")
      : component === "day" ? dirname(dirname(path)) : component === "entry" ? dirname(path)
      : component === "receipt" ? path : audioPath;
    chmodSync(target, component === "receipt" || component === "audio" ? 0o644 : 0o755);
    expect(scan()).toContain(path.split("/").at(-1)!);
  });
}
test("scans a forged stage filename outside its exact sibling tree", () => {
  const moved = join(privateRoot, path.split("/").at(-1)!);
  renameSync(path, moved); path = moved;
  expect(scan()).toContain(path.split("/").at(-1)!);
});
test("reports an aliased receipt without reading its target", () => {
  const moved = join(root, "owned-receipt");
  renameSync(path, moved); symlinkSync(moved, path);
  expect(scan()).toContain(path.split("/").at(-1)!);
});
test("reports an aliased stage ancestor without descending", () => {
  const stages = join(privateRoot, "transcription-stages");
  const moved = join(root, "owned-stages");
  renameSync(stages, moved); symlinkSync(moved, stages);
  expect(scan()).toContain("transcription-stages");
});
test("scans hardlinked receipts and missing audio", () => {
  linkSync(path, join(root, "receipt-alias"));
  expect(scan()).toContain(path.split("/").at(-1)!);
  rmSync(join(root, "receipt-alias")); rmSync(audioPath);
  expect(scan()).toContain(path.split("/").at(-1)!);
});
