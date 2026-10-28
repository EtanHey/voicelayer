import { describe, expect, test } from "bun:test";
import { readUpdateGate, transitionUpdateGate } from "../update-gate";

const initial = { version: 1, kind: "OPEN", generation: 0, released: null };
const lease = {
  generation: 1,
  operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001",
  targetSha: "a".repeat(40),
};
const competitor = { ...lease, operationId: "10000000-0000-4000-8000-000000000002" };
const ack = (token = lease) => ({ lease: token, activeOperations: 0, openArchives: 0 });
const prepare = (token = lease) => ({ kind: "PREPARE", lease: token, native: ack(token), daemon: ack(token) });
function apply(state: unknown, command: unknown) {
  const result = transitionUpdateGate(state, command);
  if (result.kind === "REFUSED") throw new Error(result.reason);
  return result.state;
}
const request = (token = lease) => ({ kind: "REQUEST", lease: token });
const draining = () => apply(initial, request());
const prepared = () => apply(draining(), prepare());
const committed = () => apply(prepared(), { kind: "COMMIT", lease });
const restart = (state: unknown): unknown => JSON.parse(JSON.stringify(state));

describe("update gate schema and ownership", () => {
  test.each([undefined, null, {}, "", { ...initial, version: 2 }, { ...initial, extra: true },
    { ...initial, generation: -1 }, { ...initial, generation: 1 },
    { ...initial, generation: Number.MAX_SAFE_INTEGER + 1 }])("unknown state refuses mutation: %j", (state) => {
    expect(readUpdateGate(state)).toEqual({ kind: "UNKNOWN" });
    expect(transitionUpdateGate(state, request())).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  });

  test("two contenders cannot both prepare or commit in either serialized order", () => {
    for (const [winner, loser] of [[lease, competitor], [competitor, lease]]) {
      let state = apply(initial, request(winner));
      const snapshot = restart(state);
      for (const command of [request(loser), prepare(loser), { kind: "COMMIT", lease: loser }]) {
        expect(transitionUpdateGate(state, command).kind).toBe("REFUSED");
      }
      expect(state).toEqual(snapshot);
      state = apply(state, prepare(winner));
      state = apply(state, { kind: "COMMIT", lease: winner });
      expect(state.kind).toBe("COMMITTED");
      expect(transitionUpdateGate(state, { kind: "COMMIT", lease: loser }).kind).toBe("REFUSED");
    }
  });

  test("obsolete generation cannot release, prepare or commit a newer gate", () => {
    const released = apply(draining(), { kind: "CANCEL", lease });
    const next = { ...competitor, generation: 2 };
    const state = apply(released, request(next));
    for (const command of [request(), prepare(), { kind: "CANCEL", lease }, { kind: "COMMIT", lease }]) {
      expect(transitionUpdateGate(state, command).kind).toBe("REFUSED");
    }
    expect(state.kind).toBe("DRAINING");
  });

  test("a restarted updater cannot substitute a new owner incarnation", () => {
    const restartedOwner = { ...lease, ownerId: competitor.operationId };
    for (const state of [draining(), prepared(), committed()]) {
      for (const command of [request(restartedOwner), prepare(restartedOwner),
        { kind: "CANCEL", lease: restartedOwner }, { kind: "COMMIT", lease: restartedOwner }]) {
        expect(transitionUpdateGate(restart(state), command).kind).toBe("REFUSED");
      }
    }
  });

  test("a competing higher generation cannot replace or commit over the closed generation", () => {
    const newer = { ...competitor, generation: 2 };
    let state = draining();
    for (const command of [request(newer), prepare(newer), { kind: "COMMIT", lease: newer }]) {
      expect(transitionUpdateGate(state, command).kind).toBe("REFUSED");
    }
    state = apply(state, prepare());
    expect(apply(state, { kind: "COMMIT", lease }).kind).toBe("COMMITTED");
  });

  test("duplicate requests and commits survive restart without resetting or repeating commit", () => {
    for (const state of [draining(), prepared(), committed()]) {
      expect(transitionUpdateGate(restart(state), request())).toEqual({ kind: "UNCHANGED", state });
    }
    const state = committed();
    expect(transitionUpdateGate(restart(state), { kind: "COMMIT", lease })).toEqual({ kind: "UNCHANGED", state });
    expect(transitionUpdateGate(state, { kind: "CANCEL", lease }).kind).toBe("REFUSED");
    expect(transitionUpdateGate(state, prepare()).kind).toBe("REFUSED");
  });

  test("precommit cancellation is idempotent but cannot resurrect the released request", () => {
    for (const state of [draining(), prepared()]) {
      const cancelled = apply(state, { kind: "CANCEL", lease });
      expect(cancelled.kind).toBe("OPEN");
      expect(transitionUpdateGate(restart(cancelled), { kind: "CANCEL", lease })).toEqual({ kind: "UNCHANGED", state: cancelled });
      expect(transitionUpdateGate(cancelled, request()).kind).toBe("REFUSED");
    }
  });

  test("both acknowledgements must match the lease and report zero work and archive writes", () => {
    const state = draining();
    for (const role of ["native", "daemon"]) {
      for (const evidence of [undefined, ack(competitor), { ...ack(), activeOperations: 1 },
        { ...ack(), openArchives: 1 }, { ...ack(), activeOperations: -1 }]) {
        expect(transitionUpdateGate(state, { ...prepare(), [role]: evidence }).kind).toBe("REFUSED");
      }
    }
    expect(transitionUpdateGate(state, { kind: "COMMIT", lease }).kind).toBe("REFUSED");
    expect(apply(state, prepare()).kind).toBe("PREPARED");
  });

  test("target, generation and owner remain bound through every transition", () => {
    for (const token of [{ ...lease, targetSha: "b".repeat(40) }, { ...lease, generation: 2 },
      { ...lease, ownerId: competitor.operationId }]) {
      for (const command of [request(token), prepare(token), { kind: "CANCEL", lease: token }, { kind: "COMMIT", lease: token }]) {
        expect(transitionUpdateGate(prepared(), command).kind).toBe("REFUSED");
      }
    }
    expect(transitionUpdateGate(initial, request({ ...lease, generation: 2 })).kind).toBe("REFUSED");
    expect(transitionUpdateGate(initial, request({ ...lease, targetSha: "latest" })).kind).toBe("REFUSED");
  });

  test("malformed persisted preparation is UNKNOWN, never idle", () => {
    const state = prepared();
    for (const invalid of [{ ...state, native: ack(competitor) }, { ...state, daemon: null },
      { ...state, native: { ...ack(), openArchives: 1 } }, { ...state, generation: 9 }]) {
      expect(readUpdateGate(invalid)).toEqual({ kind: "UNKNOWN" });
    }
  });
});
