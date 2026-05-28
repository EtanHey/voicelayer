export type VoiceSdkSpeakStopReason =
  | "completed"
  | "interrupted"
  | "cancelled"
  | "error";

export type VoiceSdkListenMode = "vad" | "push_to_talk" | "continuous";

export interface VoiceSdkEventBase {
  session_id: string;
  sequence: number;
}

export type VoiceSdkEvent =
  | (VoiceSdkEventBase & {
      type: "session.started";
      product: string;
      artifact_id?: string;
      created_at: string;
    })
  | (VoiceSdkEventBase & {
      type: "section.started";
      section_id: string;
      title: string;
      ordinal: number;
    })
  | (VoiceSdkEventBase & {
      type: "speak.started";
      utterance_id: string;
      voice_id: string;
      text_preview: string;
    })
  | (VoiceSdkEventBase & {
      type: "speak.chunk";
      utterance_id: string;
      index: number;
      text?: string;
      audio_ref?: string;
      final?: boolean;
    })
  | (VoiceSdkEventBase & {
      type: "speak.stopped";
      utterance_id: string;
      reason: VoiceSdkSpeakStopReason;
    })
  | (VoiceSdkEventBase & {
      type: "listen.started";
      turn_id: string;
      mode: VoiceSdkListenMode;
    })
  | (VoiceSdkEventBase & {
      type: "user.speech_started";
      turn_id: string;
      onset_ms: number;
    })
  | (VoiceSdkEventBase & {
      type: "user.interrupted";
      turn_id: string;
      stopped_utterance_id: string;
      onset_to_stop_ms: number;
    })
  | (VoiceSdkEventBase & {
      type: "transcript.partial";
      turn_id: string;
      text: string;
      confidence?: number;
    })
  | (VoiceSdkEventBase & {
      type: "transcript.final";
      turn_id: string;
      raw_text: string;
      cleaned_text?: string;
      stt_backend: string;
      cleanup_backend?: string;
    })
  | (VoiceSdkEventBase & {
      type: "answer.final";
      turn_id: string;
      text: string;
      applies_to?: string;
    })
  | (VoiceSdkEventBase & {
      type: "decision.recorded";
      decision_id: string;
      artifact_ref: string;
      summary: string;
      status: string;
    })
  | (VoiceSdkEventBase & {
      type: "artifact.patch_proposed";
      artifact_ref: string;
      patch_ref: string;
      summary: string;
    })
  | (VoiceSdkEventBase & {
      type: "artifact.patch_applied";
      artifact_ref: string;
      patch_ref: string;
    })
  | (VoiceSdkEventBase & {
      type: "session.ended";
      reason: string;
      duration_ms: number;
    });

export type VoiceSdkCommand =
  | {
      cmd: "session.start";
      product: string;
      artifact_id?: string;
    }
  | {
      cmd: "section.start";
      session_id: string;
      section_id: string;
      title: string;
      ordinal: number;
    }
  | {
      cmd: "speak";
      session_id: string;
      text: string;
      voice_id?: string;
    }
  | {
      cmd: "listen";
      session_id: string;
      mode?: VoiceSdkListenMode;
      timeout_ms?: number;
    }
  | {
      cmd: "decision.record";
      session_id: string;
      artifact_ref: string;
      summary: string;
      status: string;
    }
  | {
      cmd: "session.end";
      session_id: string;
      reason: string;
    };

export function serializeVoiceSdkEvent(event: VoiceSdkEvent): string {
  return JSON.stringify(event) + "\n";
}

export function parseVoiceSdkCommand(line: string): VoiceSdkCommand | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed) || typeof parsed.cmd !== "string") return null;

  switch (parsed.cmd) {
    case "session.start": {
      const product = stringValue(parsed.product);
      if (!product) return null;
      return {
        cmd: "session.start",
        product,
        ...(stringValue(parsed.artifact_id)
          ? { artifact_id: stringValue(parsed.artifact_id) }
          : {}),
      };
    }
    case "section.start": {
      const sessionId = stringValue(parsed.session_id);
      const sectionId = stringValue(parsed.section_id);
      const title = stringValue(parsed.title);
      if (!sessionId || !sectionId || !title || typeof parsed.ordinal !== "number") {
        return null;
      }
      return {
        cmd: "section.start",
        session_id: sessionId,
        section_id: sectionId,
        title,
        ordinal: parsed.ordinal,
      };
    }
    case "speak": {
      const sessionId = stringValue(parsed.session_id);
      const text = stringValue(parsed.text);
      if (!sessionId || !text) return null;
      return {
        cmd: "speak",
        session_id: sessionId,
        text,
        ...(stringValue(parsed.voice_id)
          ? { voice_id: stringValue(parsed.voice_id) }
          : {}),
      };
    }
    case "listen": {
      const sessionId = stringValue(parsed.session_id);
      if (!sessionId) return null;
      const mode = parseListenMode(parsed.mode);
      return {
        cmd: "listen",
        session_id: sessionId,
        ...(mode ? { mode } : {}),
        ...(typeof parsed.timeout_ms === "number"
          ? { timeout_ms: Math.max(1, parsed.timeout_ms) }
          : {}),
      };
    }
    case "decision.record": {
      const sessionId = stringValue(parsed.session_id);
      const artifactRef = stringValue(parsed.artifact_ref);
      const summary = stringValue(parsed.summary);
      const status = stringValue(parsed.status);
      if (!sessionId || !artifactRef || !summary || !status) return null;
      return {
        cmd: "decision.record",
        session_id: sessionId,
        artifact_ref: artifactRef,
        summary,
        status,
      };
    }
    case "session.end": {
      const sessionId = stringValue(parsed.session_id);
      const reason = stringValue(parsed.reason);
      if (!sessionId || !reason) return null;
      return {
        cmd: "session.end",
        session_id: sessionId,
        reason,
      };
    }
    default:
      return null;
  }
}

function parseListenMode(value: unknown): VoiceSdkListenMode | undefined {
  if (value === "vad" || value === "push_to_talk" || value === "continuous") {
    return value;
  }
  return undefined;
}

function stringValue(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
