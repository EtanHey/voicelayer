import { expect, it, spyOn } from "bun:test";
import * as client from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import { testSocket } from "./setup/test-tmp";
import { deferredFixture as deferred } from "./long-read-fixture-barriers";

it("CLICK2 d: real command transport emits timestamped allowlisted receipt/outcome lines without selection text", async () => {
  const lines: string[] = [];
  const log = spyOn(console, "error").mockImplementation((...args: unknown[]) => { lines.push(args.map(String).join(" ")); });
  const connected = deferred<Bun.Socket<unknown>>();
  const ack = deferred<void>();
  const selection = "CLICK2_SYNTHETIC_PRIVATE_SELECTION_payload_must_not_leak";
  const server = Bun.listen({ unix: testSocket("c2.sock"), socket: {
    open(peer) { connected.resolve(peer); },
    data(_peer, bytes) {
      for (const line of bytes.toString().split("\n")) {
        if (line && JSON.parse(line).id === "click2-log") ack.resolve();
      }
    }, drain() {}, close() {}, error() {},
  } });
  try {
    client.onCommand(command => command.cmd === "speak_text"
      ? { type: "ack", command: command.cmd, id: command.id, outcome: "accept" }
      : handleSocketCommand(command));
    client.connectToBar(testSocket("c2.sock"), { role: "mcp-daemon", acceptsCommands: true });
    const peer = await connected.promise;
    // Exercise a real content-bearing command through the parser/logger, with no speech I/O.
    peer.write(JSON.stringify({ cmd: "speak_text", id: "click2-private", text: selection }) + "\n");
    peer.write(JSON.stringify({ cmd: "pause", id: "click2-log" }) + "\n");
    await ack.promise;
    expect(lines.join("\n")).not.toContain(selection);
    // Proposed JSONL schema: one allowlisted object on each diagnostic line, no wire payload.
    const records = lines.flatMap(line => {
      try { return [JSON.parse(line.slice(line.indexOf("{")))]; } catch { return []; }
    });
    for (const event of ["command_receipt", "command_outcome"]) {
      const record = records.find(record => record.event === event && record.command_id === "click2-log");
      expect(record).toBeDefined();
      expect(record).toMatchObject({ command: "pause", phase: "none", generation: null });
      expect(Number.isFinite(Date.parse(record.timestamp))).toBe(true);
      if (event === "command_outcome") expect(record).toMatchObject({ outcome: "noop", reason: "nothing playing" });
      expect(Object.keys(record).some(key => /text|selection|payload/i.test(key))).toBe(false);
    }
  } finally {
    client.disconnectFromBar(); client.onCommand(() => {}); server.stop(true); log.mockRestore();
  }
});

it("CLICK2 d2: a handler throw and a free-text reason are logged as bounded outcomes, never echoed", async () => {
  const lines: string[] = [];
  const log = spyOn(console, "error").mockImplementation((...args: unknown[]) => { lines.push(args.map(String).join(" ")); });
  const connected = deferred<Bun.Socket<unknown>>();
  const ack = deferred<void>();
  const secret = "CLICK2_SYNTHETIC_PRIVATE_SELECTION_reason_must_not_leak";
  const server = Bun.listen({ unix: testSocket("c3.sock"), socket: {
    open(peer) { connected.resolve(peer); },
    data(_peer, bytes) {
      for (const line of bytes.toString().split("\n")) if (line && JSON.parse(line).id === "click2-free") ack.resolve();
    }, drain() {}, close() {}, error() {},
  } });
  try {
    client.onCommand(command => {
      if (command.id === "click2-throw") throw new Error(secret);
      return { type: "ack", command: command.cmd, id: command.id, outcome: "reject", reason: secret };
    });
    client.connectToBar(testSocket("c3.sock"), { role: "mcp-daemon", acceptsCommands: true });
    const peer = await connected.promise;
    peer.write(JSON.stringify({ cmd: "pause", id: "click2-throw" }) + "\n");
    peer.write(JSON.stringify({ cmd: "replay", id: "click2-free" }) + "\n");
    await ack.promise;
    expect(lines.join("\n")).not.toContain(secret);
    const records = lines.flatMap(line => {
      try { return [JSON.parse(line.slice(line.indexOf("{")))]; } catch { return []; }
    });
    expect(records.find(record => record.event === "command_outcome" && record.command_id === "click2-throw"))
      .toMatchObject({ command: "pause", outcome: "failed", reason: "handler-failed" });
    expect(records.find(record => record.event === "command_outcome" && record.command_id === "click2-free"))
      .toMatchObject({ command: "replay", outcome: "reject", reason: "unlisted" });
  } finally {
    client.disconnectFromBar(); client.onCommand(() => {}); server.stop(true); log.mockRestore();
  }
});
