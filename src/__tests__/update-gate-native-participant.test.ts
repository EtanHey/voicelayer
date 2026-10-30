import { expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { createNativeDrainParticipant, drainMessage } from "../update-gate-native-participant";
const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
test("fresh signed native reply binds full lease, nonce, PID and incarnation", async () => {
  let request: Parameters<typeof drainMessage>[1] | undefined;
  const participant = createNativeDrainParticipant({ secret: "synthetic", nativePid: 123, send: value => { request = value; } });
  const result = participant.request(lease);
  if (!request) throw Error("request not sent");
  const reply = { ...request, cmd: "update_gate_drain_ack", pid: 123, incarnation: crypto.randomUUID(), mac: "" };
  reply.mac = createHmac("sha256", "synthetic").update(drainMessage("ack-drain", reply)).digest("hex");
  participant.receive({ ...reply, pid: 456 }); // Cannot spoof the native process.
  participant.receive({ ...reply, lease: { ...lease, generation: 2 } });
  participant.receive(reply);
  expect(await result).toMatchObject({ lease, pid: 123, incarnation: reply.incarnation });
  participant.receive(reply); // A replay has no pending nonce.
});
test("missing inherited identity and disconnected participant refuse UNKNOWN", async () => {
  const absent = createNativeDrainParticipant({ send() {} });
  expect(await absent.request(lease)).toBeNull();
  const participant = createNativeDrainParticipant({ secret: "synthetic", nativePid: 123, send() {} });
  const pending = participant.request(lease);
  participant.disconnect();
  expect(await pending).toBeNull();
});
test("malformed native incarnation cannot become participant evidence even with a valid MAC", async () => {
  let request: Parameters<typeof drainMessage>[1] | undefined;
  const participant = createNativeDrainParticipant({ secret: "synthetic", nativePid: 123, send: value => { request = value; } });
  const result = participant.request(lease);
  if (!request) throw Error("request not sent");
  const reply = { ...request, cmd: "update_gate_drain_ack", pid: 123, incarnation: "-".repeat(36) };
  participant.receive({ ...reply, mac: createHmac("sha256", "synthetic").update(drainMessage("ack-drain", reply)).digest("hex") });
  participant.disconnect();
  expect(await result).toBeNull();
});
test("updater control requires the existing authenticated control token", async () => {
  const { createSpeechControl } = await import("../speech-control");
  let calls = 0;
  const control = createSpeechControl("synthetic", () => { throw Error("not media"); }, async (value, action) => {
    calls++; return { value, action };
  });
  await expect(control({ cmd: "update_gate_drain", lease, token: "wrong" })).rejects.toThrow("Unauthorized");
  expect(calls).toBe(0);
  expect(await control({ cmd: "update_gate_drain", lease, token: "synthetic" })).toEqual({ value: lease, action: "drain" });
  expect(await control({ cmd: "update_gate_quit", lease, token: "synthetic" })).toEqual({ value: lease, action: "quit" });
});
test("live evidence rechecks G2 after the native round trip and never quits before COMMITTED", async () => {
  const { mkdtempSync, writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { initializeVoiceGate, updateVoiceGate } = await import("../update-gate-admission");
  const { createVoiceDrainControl } = await import("../update-gate-native-participant");
  const saved = process.env.VOICELAYER_UPDATE_GATE_PATH;
  const path = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "native-")), "gate");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  try {
    await initializeVoiceGate();
    expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
    let calls = 0, fault = false;
    const control = createVoiceDrainControl({ request: async () => {
      calls++;
      if (fault) writeFileSync(path + ".voice-diag.json", "synthetic fault", { flag: "wx" });
      return { action: "drain", id: crypto.randomUUID(), pid: 123, incarnation: crypto.randomUUID(), lease };
    } }, () => true);
    expect(await control(lease, "quit")).toEqual({ kind: "UNKNOWN" });
    expect(calls).toBe(0);
    expect(await control(lease, "drain")).toMatchObject({ kind: "ACKNOWLEDGED", native: { lease }, daemon: { lease } });
    fault = true;
    expect(await control(lease, "drain")).toEqual({ kind: "UNKNOWN" });
    expect(calls).toBe(2);
  } finally { process.env.VOICELAYER_UPDATE_GATE_PATH = saved; }
});
