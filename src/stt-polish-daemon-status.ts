import type { SocketEvent } from "./socket-protocol";
import type { STTPolishServerStatus } from "./stt-polish-server";

type BroadcastPolishStatus = (event: SocketEvent) => void;

const MISSING_BINARY_HINT =
  "STT polish unavailable — install mlx-lm (`uv tool install mlx-lm` or `pip install mlx-lm`)";
const LAUNCH_TIMEOUT_HINT =
  "STT polish unavailable — local polish server did not become ready";

export interface STTPolishStatusReporter {
  report(status: STTPolishServerStatus): void;
  reportLaunchFailure(error: unknown): void;
  replay(): void;
}

export function createSTTPolishStatusReporter(
  broadcast: BroadcastPolishStatus,
): STTPolishStatusReporter {
  let currentEvent: SocketEvent | null = null;

  const emit = (event: SocketEvent): void => {
    if (currentEvent && JSON.stringify(currentEvent) === JSON.stringify(event)) {
      return;
    }
    currentEvent = event;
    broadcast(event);
  };

  return {
    report(status) {
      switch (status.status) {
        case "missing-binary":
          emit({
            type: "polish_degraded",
            reason: "missing-binary",
            hint: MISSING_BINARY_HINT,
          });
          break;
        case "timeout":
          emit({
            type: "polish_degraded",
            reason: "launch-timeout",
            hint: LAUNCH_TIMEOUT_HINT,
          });
          break;
        case "launch-failed":
          emit({
            type: "polish_degraded",
            reason: "launch-failed",
            hint: `STT polish unavailable — local polish server failed to start: ${status.error}`,
          });
          break;
        case "already-ready":
        case "ready":
        case "disabled":
        case "external":
          emit({ type: "polish_ready" });
          break;
        case "starting":
          break;
      }
    },
    reportLaunchFailure(error) {
      const detail = error instanceof Error ? error.message : String(error);
      emit({
        type: "polish_degraded",
        reason: "launch-failed",
        hint: `STT polish unavailable — local polish server failed to start: ${detail}`,
      });
    },
    replay() {
      if (currentEvent) broadcast(currentEvent);
    },
  };
}

export async function ensureAndReportSTTPolishServer(options: {
  ensure: () => Promise<STTPolishServerStatus>;
  reporter: STTPolishStatusReporter;
}): Promise<void> {
  try {
    options.reporter.report(await options.ensure());
  } catch (error) {
    options.reporter.reportLaunchFailure(error);
  }
}
