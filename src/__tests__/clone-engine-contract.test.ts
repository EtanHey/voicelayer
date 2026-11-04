import { describe, expect, it } from "bun:test";
import { parseCommand, serializeEvent, type SocketEvent } from "../socket-protocol";

describe("clone engine app-owned wire contract", () => {
  it("accepts each action with request correlation", () => {
    for (const action of ["start", "restart", "stop", "set_autostart"]) {
      const payload = {cmd: "clone_engine", action, id: "engine-1", ...(action === "set_autostart" ? {value: false} : {})};
      expect(parseCommand(JSON.stringify(payload))).toEqual(payload);
    }
  });
  it("rejects malformed actions and non-boolean preferences", () => {
    for (const extra of [{action: "kill"}, {action: "set_autostart"}, {action: "set_autostart", value: 1}, {action: "start", value: true}]) {
      expect(parseCommand(JSON.stringify({cmd: "clone_engine", ...extra}))).toBeNull();
    }
  });
  it("uses the existing correlated acknowledgement shape", () => {
    const ack: SocketEvent = {type: "ack", command: "clone_engine", outcome: "reject", id: "engine-1", reason: "foreign_engine"};
    expect(JSON.parse(serializeEvent(ack))).toEqual(ack);
  });
  it("preserves nullable identity and the default-on preference", () => {
    const event = {type: "clone_engine", state: "starting", since: "2026-11-05T00:00:00Z", reason: null, pid: null, start_with_voicebar: true};
    expect(JSON.parse(serializeEvent(event as SocketEvent))).toEqual(event);
  });
});
