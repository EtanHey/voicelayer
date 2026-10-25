import { expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";
import { createSpeakReceipt } from "../speak-archive";
import { transitionSpeakArchive, recoverSpeakArchive } from "../speak-archive-store";
function receipt() {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const result = createSpeakReceipt({ input: "  exact original\n", request_id: crypto.randomUUID(), request_source: "selection",
    connection: "daemon", format: "plain", blocking: false,
    requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
    build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
  if (result.kind !== "created") throw new Error(result.code);
  return result.context;
}
for (const terminal of ["completed", "stopped", "cancelled", "failed"] as const) {
  test(`state store durably writes ${terminal} without changing original input`, () => {
    const c = receipt();
    expect(transitionSpeakArchive(c, "preparing").kind).toBe("stored");
    expect(transitionSpeakArchive(c, "playing").kind).toBe("stored");
    expect(transitionSpeakArchive(c, terminal, "FIXTURE_REASON").kind).toBe("stored");
    const m = JSON.parse(readFileSync(join(c.path, "metadata.json"), "utf8"));
    expect(m.speech).toMatchObject({ state: terminal, reason: "FIXTURE_REASON" });
    expect(m.speech.transitions.map((t: { to: string }) => t.to)).toEqual(["preparing", "playing", terminal]);
    expect(readFileSync(join(c.path, "input.txt"), "utf8")).toBe("  exact original\n");
    expect(transitionSpeakArchive(c, "playing")).toEqual({ kind: "failed", code: "CONFLICT" });
    expect(recoverSpeakArchive(c.id)).toMatchObject({ kind: "stored", metadata: { speech: { state: terminal } } });
  });
}
for (const state of ["preparing", "playing", "paused"] as const) {
  test(`restart recovers ${state} to interrupted and preserves terminal recovery`, () => {
    const c = receipt(); transitionSpeakArchive(c, "preparing");
    if (state !== "preparing") transitionSpeakArchive(c, state);
    expect(recoverSpeakArchive(c.id)).toMatchObject({ kind: "stored", metadata: { speech: { state: "interrupted", reason: "PROCESS_RESTART" } } });
    const before = readFileSync(join(c.path, "metadata.json")); recoverSpeakArchive(c.id);
    expect(readFileSync(join(c.path, "metadata.json"))).toEqual(before);
  });
}
