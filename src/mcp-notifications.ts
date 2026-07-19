import type { PlaybackOutcomeEvent } from "./socket-protocol";

export type VoiceAskProgressStage = "recording" | "transcribing";

export interface VoiceAskProgressEvent {
  kind: "voice_ask_progress";
  sequence: number;
  stage: VoiceAskProgressStage;
  elapsedMs: number;
}

export interface PlaybackOutcomeToolEvent {
  kind: "playback_outcome";
  outcome: PlaybackOutcomeEvent;
}

export type VoiceToolEvent =
  | VoiceAskProgressEvent
  | PlaybackOutcomeToolEvent;

export interface VoiceToolContext {
  emit(event: VoiceToolEvent): void;
  /** Test-only timing seam; production uses the default heartbeat interval. */
  heartbeatIntervalMs?: number;
}

export interface McpNotification {
  method: "notifications/progress" | "notifications/message";
  params: Record<string, unknown>;
}

type ProgressToken = string | number;
type NotificationSender = (
  notification: McpNotification,
) => void | Promise<void>;

const DEFAULT_HEARTBEAT_INTERVAL_MS = 15_000;

function progressMessage(event: VoiceAskProgressEvent): string {
  return `voice_ask ${event.stage} — ${Math.round(event.elapsedMs / 1000)}s elapsed`;
}

export function voiceToolEventToMcpNotification(
  event: VoiceToolEvent,
  progressToken?: ProgressToken,
): McpNotification {
  if (event.kind === "playback_outcome") {
    return {
      method: "notifications/message",
      params: {
        level: "info",
        logger: "voicelayer.playback",
        data: {
          kind: event.kind,
          ...event.outcome,
        },
      },
    };
  }

  const message = progressMessage(event);
  if (progressToken !== undefined) {
    return {
      method: "notifications/progress",
      params: {
        progressToken,
        progress: event.sequence,
        message,
      },
    };
  }

  return {
    method: "notifications/message",
    params: {
      level: "info",
      logger: "voicelayer.voice_ask",
      data: {
        kind: event.kind,
        sequence: event.sequence,
        stage: event.stage,
        elapsed_ms: event.elapsedMs,
        message,
      },
    },
  };
}

export function createVoiceToolContext(
  progressToken: ProgressToken | undefined,
  sendNotification?: NotificationSender,
): VoiceToolContext {
  return {
    emit(event) {
      if (!sendNotification) return;
      const notification = voiceToolEventToMcpNotification(
        event,
        progressToken,
      );
      try {
        void Promise.resolve(sendNotification(notification)).catch((error) => {
          console.error(
            `[voicelayer] MCP notification failed: ${error instanceof Error ? error.message : String(error)}`,
          );
        });
      } catch (error) {
        console.error(
          `[voicelayer] MCP notification failed: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    },
  };
}

export class VoiceAskProgressHeartbeat {
  private startedAt: number | null = null;
  private sequence = 0;
  private stage: VoiceAskProgressStage | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly context: VoiceToolContext) {}

  start(stage: VoiceAskProgressStage): void {
    if (this.timer) return;
    this.startedAt = Date.now();
    this.stage = stage;
    this.emit();
    this.timer = setInterval(
      () => this.emit(),
      this.context.heartbeatIntervalMs ?? DEFAULT_HEARTBEAT_INTERVAL_MS,
    );
  }

  setStage(stage: VoiceAskProgressStage): void {
    if (!this.timer || this.stage === stage) return;
    this.stage = stage;
    this.emit();
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  private emit(): void {
    if (!this.stage) return;
    this.context.emit({
      kind: "voice_ask_progress",
      sequence: ++this.sequence,
      stage: this.stage,
      elapsedMs: this.startedAt === null ? 0 : Date.now() - this.startedAt,
    });
  }
}
