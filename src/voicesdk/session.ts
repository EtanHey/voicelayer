import { appendFileSync, mkdirSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import type { BargeInMonitor, SoundLayer } from "../soundlayer";
import { defaultSoundLayer } from "../soundlayer";
import {
  serializeVoiceSdkEvent,
  type VoiceSdkEvent,
  type VoiceSdkListenMode,
  type VoiceSdkSpeakStopReason,
} from "./protocol";

export interface VoiceSdkSession {
  session_id: string;
  product: string;
  artifact_id?: string;
  created_at: string;
  sequence: number;
  startedAtMs: number;
  ended: boolean;
}

export interface VoiceSdkSessionManagerOptions {
  soundLayer?: SoundLayer;
  logDir?: string;
  idFactory?: () => string;
  now?: () => Date;
  onEvent?: (event: VoiceSdkEvent) => void;
}

export interface StartSessionInput {
  product: string;
  artifact_id?: string;
}

export interface StartSectionInput {
  section_id: string;
  title: string;
  ordinal: number;
}

export interface SpeakInput {
  text: string;
  voice_id?: string;
}

export interface ListenInput {
  mode?: VoiceSdkListenMode;
  timeout_ms?: number;
}

export interface DecisionInput {
  artifact_ref: string;
  summary: string;
  status: string;
}

export interface VoiceSdkSessionManager {
  startSession(input: StartSessionInput): Promise<VoiceSdkSession>;
  startSection(sessionId: string, input: StartSectionInput): Promise<void>;
  speak(sessionId: string, input: SpeakInput): Promise<void>;
  listen(sessionId: string, input: ListenInput): Promise<void>;
  recordDecision(sessionId: string, input: DecisionInput): Promise<void>;
  endSession(sessionId: string, reason: string): Promise<void>;
  replay(sessionId: string): VoiceSdkEvent[];
  subscribe(listener: (event: VoiceSdkEvent) => void): () => void;
}

const DEFAULT_LOG_DIR = join(homedir(), ".voicelayer", "voicesdk-sessions");

export function createVoiceSdkSessionManager(
  options: VoiceSdkSessionManagerOptions = {},
): VoiceSdkSessionManager {
  const soundLayer = options.soundLayer ?? defaultSoundLayer;
  const logDir = options.logDir ?? DEFAULT_LOG_DIR;
  const idFactory = options.idFactory ?? randomSessionId;
  const now = options.now ?? (() => new Date());
  const sessions = new Map<string, VoiceSdkSession>();
  const listeners = new Set<(event: VoiceSdkEvent) => void>();

  if (options.onEvent) listeners.add(options.onEvent);

  function sessionFor(sessionId: string): VoiceSdkSession {
    const session = sessions.get(sessionId);
    if (!session) throw new Error(`Unknown VoiceSDK session: ${sessionId}`);
    if (session.ended) throw new Error(`VoiceSDK session has ended: ${sessionId}`);
    return session;
  }

  function nextSequence(session: VoiceSdkSession): number {
    session.sequence += 1;
    return session.sequence;
  }

  function emit(event: VoiceSdkEvent): void {
    mkdirSync(logDir, { recursive: true });
    appendFileSync(logPath(logDir, event.session_id), serializeVoiceSdkEvent(event));
    for (const listener of listeners) {
      listener(event);
    }
  }

  async function startSession(
    input: StartSessionInput,
  ): Promise<VoiceSdkSession> {
    const created = now();
    const session: VoiceSdkSession = {
      session_id: idFactory(),
      product: input.product,
      ...(input.artifact_id ? { artifact_id: input.artifact_id } : {}),
      created_at: created.toISOString(),
      sequence: 0,
      startedAtMs: created.getTime(),
      ended: false,
    };
    sessions.set(session.session_id, session);
    emit({
      type: "session.started",
      session_id: session.session_id,
      product: input.product,
      ...(input.artifact_id ? { artifact_id: input.artifact_id } : {}),
      created_at: session.created_at,
      sequence: nextSequence(session),
    });
    return session;
  }

  async function startSection(
    sessionId: string,
    input: StartSectionInput,
  ): Promise<void> {
    const session = sessionFor(sessionId);
    emit({
      type: "section.started",
      session_id: sessionId,
      section_id: input.section_id,
      title: input.title,
      ordinal: input.ordinal,
      sequence: nextSequence(session),
    });
  }

  async function speak(sessionId: string, input: SpeakInput): Promise<void> {
    const session = sessionFor(sessionId);
    const utteranceId = `utt-${session.sequence + 1}`;
    const voiceId = input.voice_id ?? "default";
    let playbackStartedAtMs = soundLayer.clock?.nowMs() ?? Date.now();
    let reason: VoiceSdkSpeakStopReason = "completed";
    let interrupted = false;
    const bargeInMonitor: { current: BargeInMonitor | null } = {
      current: null,
    };

    emit({
      type: "speak.started",
      session_id: sessionId,
      utterance_id: utteranceId,
      voice_id: voiceId,
      text_preview: input.text.slice(0, 160),
      sequence: nextSequence(session),
    });
    emit({
      type: "speak.chunk",
      session_id: sessionId,
      utterance_id: utteranceId,
      index: 0,
      text: input.text,
      final: true,
      sequence: nextSequence(session),
    });

    const startBargeInMonitor = (startedAtMs: number) => {
      if (!soundLayer.bargeIn || bargeInMonitor.current) return;
      playbackStartedAtMs = startedAtMs;
      bargeInMonitor.current = soundLayer.bargeIn.monitorDuringPlayback({
        playbackStartedAtMs,
        onSpeechStart: (onset) => {
          if (interrupted) return;
          interrupted = true;
          const turnId = `turn-${session.sequence + 1}`;
          emit({
            type: "listen.started",
            session_id: sessionId,
            turn_id: turnId,
            mode: "vad",
            sequence: nextSequence(session),
          });
          emit({
            type: "user.speech_started",
            session_id: sessionId,
            turn_id: turnId,
            onset_ms: onset.onset_ms,
            sequence: nextSequence(session),
          });
          soundLayer.cancellation.stopPlayback();
          const stoppedAtMs = soundLayer.clock?.nowMs() ?? Date.now();
          const onsetAbsoluteMs = playbackStartedAtMs + onset.onset_ms;
          emit({
            type: "user.interrupted",
            session_id: sessionId,
            turn_id: turnId,
            stopped_utterance_id: utteranceId,
            onset_to_stop_ms: Math.max(0, stoppedAtMs - onsetAbsoluteMs),
            sequence: nextSequence(session),
          });
        },
      });
    };

    try {
      await soundLayer.tts.speak(input.text, {
        voice: input.voice_id,
        mode: "converse",
        waitForPlayback: true,
        onPlaybackStart: startBargeInMonitor,
      });
    } catch {
      reason = "error";
    } finally {
      bargeInMonitor.current?.stop();
    }
    if (interrupted) {
      reason = "interrupted";
    }
    emit({
      type: "speak.stopped",
      session_id: sessionId,
      utterance_id: utteranceId,
      reason,
      sequence: nextSequence(session),
    });
  }

  async function listen(sessionId: string, input: ListenInput): Promise<void> {
    const session = sessionFor(sessionId);
    const mode = input.mode ?? "vad";
    const turnId = `turn-${session.sequence + 1}`;
    emit({
      type: "listen.started",
      session_id: sessionId,
      turn_id: turnId,
      mode,
      sequence: nextSequence(session),
    });
    const text = await soundLayer.micCapture.waitForInput(
      input.timeout_ms ?? 30_000,
      "standard",
      mode === "push_to_talk",
      { archiveRecording: true, barOwned: false },
    );
    if (text === null) {
      emit({
        type: "transcript.final",
        session_id: sessionId,
        turn_id: turnId,
        raw_text: "",
        stt_backend: "soundlayer.micCapture",
        sequence: nextSequence(session),
      });
      return;
    }
    emit({
      type: "transcript.final",
      session_id: sessionId,
      turn_id: turnId,
      raw_text: text,
      cleaned_text: text,
      stt_backend: "soundlayer.micCapture",
      sequence: nextSequence(session),
    });
    emit({
      type: "answer.final",
      session_id: sessionId,
      turn_id: turnId,
      text,
      sequence: nextSequence(session),
    });
  }

  async function recordDecision(
    sessionId: string,
    input: DecisionInput,
  ): Promise<void> {
    const session = sessionFor(sessionId);
    emit({
      type: "decision.recorded",
      session_id: sessionId,
      decision_id: `decision-${session.sequence + 1}`,
      artifact_ref: input.artifact_ref,
      summary: input.summary,
      status: input.status,
      sequence: nextSequence(session),
    });
  }

  async function endSession(sessionId: string, reason: string): Promise<void> {
    const session = sessionFor(sessionId);
    const endedAtMs = now().getTime();
    emit({
      type: "session.ended",
      session_id: sessionId,
      reason,
      duration_ms: Math.max(0, endedAtMs - session.startedAtMs),
      sequence: nextSequence(session),
    });
    session.ended = true;
  }

  function replay(sessionId: string): VoiceSdkEvent[] {
    const path = logPath(logDir, sessionId);
    try {
      const contents = readFileSync(path, "utf-8").trim();
      if (!contents) return [];
      return contents.split("\n").map((line) => JSON.parse(line) as VoiceSdkEvent);
    } catch {
      return [];
    }
  }

  function subscribe(listener: (event: VoiceSdkEvent) => void): () => void {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }

  return {
    startSession,
    startSection,
    speak,
    listen,
    recordDecision,
    endSession,
    replay,
    subscribe,
  };
}

function logPath(logDir: string, sessionId: string): string {
  const safeSessionId = sessionId.replace(/[^a-zA-Z0-9_.-]/g, "_");
  return join(logDir, `${safeSessionId}.ndjson`);
}

function randomSessionId(): string {
  return `session-${crypto.randomUUID()}`;
}
