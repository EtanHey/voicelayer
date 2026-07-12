import { describe, expect, it } from "bun:test";

import {
  createSTTPolishStatusReporter,
  ensureAndReportSTTPolishServer,
} from "../stt-polish-daemon-status";
import type { SocketEvent } from "../socket-protocol";

const MISSING_BINARY_HINT =
  "STT polish unavailable — install mlx-lm (`uv tool install mlx-lm` or `pip install mlx-lm`)";

describe("daemon STT polish status reporting", () => {
  it("emits exactly one degraded event when the default server binary is missing", async () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    await ensureAndReportSTTPolishServer({
      ensure: async () => ({ status: "missing-binary" }),
      reporter,
    });

    expect(events).toEqual([
      {
        type: "polish_degraded",
        reason: "missing-binary",
        hint: MISSING_BINARY_HINT,
      },
    ]);
  });

  it.each(["disabled", "external"] as const)(
    "does not report intentional %s status as degraded",
    async (status) => {
      const events: SocketEvent[] = [];
      const reporter = createSTTPolishStatusReporter((event) => events.push(event));

      await ensureAndReportSTTPolishServer({
        ensure: async () => ({ status }),
        reporter,
      });

      expect(events).not.toContainEqual(expect.objectContaining({
        type: "polish_degraded",
      }));
    },
  );

  it("clears a previous degradation when the server later becomes ready", async () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    reporter.report({ status: "missing-binary" });
    reporter.report({ status: "already-ready" });

    expect(events).toEqual([
      {
        type: "polish_degraded",
        reason: "missing-binary",
        hint: MISSING_BINARY_HINT,
      },
      { type: "polish_ready" },
    ]);
  });

  it("reports a rejected launch as degraded instead of relying on catch-only logging", async () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    await ensureAndReportSTTPolishServer({
      ensure: async () => {
        throw new Error("spawn failed");
      },
      reporter,
    });

    expect(events).toEqual([
      {
        type: "polish_degraded",
        reason: "launch-failed",
        hint: "STT polish unavailable — local polish server failed to start: spawn failed",
      },
    ]);
  });

  it("replays the current degradation after VoiceBar reconnects", () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    reporter.report({ status: "missing-binary" });
    events.length = 0;
    reporter.replay();

    expect(events).toEqual([
      {
        type: "polish_degraded",
        reason: "missing-binary",
        hint: MISSING_BINARY_HINT,
      },
    ]);
  });

  it("does not rebroadcast an unchanged status transition", () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    reporter.report({ status: "missing-binary" });
    reporter.report({ status: "missing-binary" });

    expect(events).toHaveLength(1);
  });

  it("a fresh daemon reporter authoritatively clears stale VoiceBar degradation", () => {
    const events: SocketEvent[] = [];
    const reporter = createSTTPolishStatusReporter((event) => events.push(event));

    reporter.report({ status: "already-ready" });

    expect(events).toEqual([{ type: "polish_ready" }]);
  });
});
