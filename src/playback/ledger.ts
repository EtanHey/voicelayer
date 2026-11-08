/**
 * Lane B (2.4): the daemon's single PlaybackSession ledger. The player driver
 * (PlaybackQueueManager in tts.ts) reports each edge here; the engine decides positions
 * (word indices), owns the voice_ask park/restore and the read history, and checks the
 * formal/playback-session invariants after every edge. A violation is logged (journal +
 * stderr, no text) and never thrown: playback keeps working while the evidence is kept.
 */
import { appendControlLayerEvent } from "../control-layer-journal";
import { broadcast } from "../socket-client";
import type { PlaybackSessionEvent } from "../socket-protocol";
import {
  ASK_PROMPT_ID,
  PlaybackSessionEngine,
  type AskEnd,
  type AskRestore,
  type PauseOwner,
  type PlaybackSession,
  type SessionKind,
} from "./session";

let engine = new PlaybackSessionEngine();
let speed = 1;
const reported = new Set<string>();

/** Test seam: a fresh ledger per test. */
export function resetPlaybackSessionLedger(): void {
  engine = new PlaybackSessionEngine();
  speed = 1;
  reported.clear();
}

export function playbackSessionEngine(): PlaybackSessionEngine { return engine; }
export function playbackSessionViolations(): string[] { return engine.violations(); }

export function currentPlaybackSpeed(): number { return speed; }
export function setLedgerPlaybackSpeed(value: number): void { speed = value; publish(); }

function check(edge: string): void {
  for (const violation of engine.violations()) {
    const key = `${edge}:${violation}`;
    if (reported.has(key)) continue;
    reported.add(key);
    if (reported.size > 64) reported.delete(reported.values().next().value!);
    const payload = { edge, violation };
    try { appendControlLayerEvent("playback_session_violation", payload, { topic: "voice.playback" }); } catch {}
    console.error(`[voicelayer] ${JSON.stringify({ event: "playback_session_violation", timestamp: new Date().toISOString(), ...payload })}`);
  }
}

function snapshotEvent(): PlaybackSessionEvent {
  const live = engine.live();
  let previous = false;
  try { previous = previousProbe(); } catch {}
  return {
    type: "playback_session",
    session_id: live?.id ?? null,
    phase: live?.state ?? "idle",
    word_index: live ? (live.state === "paused" || live.state === "parked" ? live.pausedAt ?? live.cursor : live.cursor) : 0,
    word_count: live?.wordCount ?? 0,
    ...(live?.pauseOwner ? { pause_owner: live.pauseOwner } : {}),
    ask: engine.ask,
    parked_by_ask: engine.parked?.id ?? null,
    previous_available: previous,
    speed,
  };
}

let lastPublished = "";
function publish(): void {
  const event = snapshotEvent();
  const key = JSON.stringify(event);
  if (key === lastPublished) return;
  lastPublished = key;
  try { broadcast(event); } catch {}
}

function after(edge: string): void { check(edge); publish(); }

/** A player for session `id` started at read-global word `word`. Begins, continues or resumes the session. */
export function ledgerPlayerStarted(id: string, kind: SessionKind, word: number, wordCount: number, isPrompt = false): void {
  if (isPrompt) {
    if (engine.ask === "none") engine.askBegin();
    engine.askPromptStart();
    return after("prompt-start");
  }
  let session: Readonly<PlaybackSession> | undefined = engine.get(id);
  if (!session || session.state === "ended" || session.state === "queued") {
    engine.begin(id, kind, wordCount);
  } else {
    engine.extend(id, wordCount);
    if (session.state === "playing") nextChunk(id);
    else if (session.state === "seeking") engine.seekDone(id);
    else if (session.state === "paused") engine.resume(id);
  }
  session = engine.get(id);
  if (session?.state === "preparing" && session.cursor !== word && session.resumedAt === undefined) {
    // A seek or an unmodelled jump: the driver's player is the truth for where audio starts.
    (session as PlaybackSession).cursor = Math.max(0, word);
  }
  engine.ready(id);
  engine.word(id, word);
  engine.teleprompter(word, id);
  after("player-started");
}

/** Chunk boundary inside one read: the next chunk's player continues the same session. */
function nextChunk(id: string): void {
  const session = engine.get(id) as PlaybackSession | undefined;
  if (!session || session.state !== "playing") return;
  session.state = "preparing";
  engine.players.delete(id);
  engine.preparing.add(id);
}

export function ledgerWord(id: string, word: number): void {
  engine.word(id, word);
  engine.teleprompter(word, id);
}

export function ledgerPlayerExited(id: string, isPrompt = false): void {
  engine.playerExited(isPrompt ? ASK_PROMPT_ID : id);
  if (isPrompt && engine.ask === "prompt") engine.askPromptEnd();
  check("player-exited");
}

export function ledgerPaused(id: string, word: number, owner: PauseOwner): void {
  engine.pause(id, word, owner);
  after("pause");
}

export function ledgerResumed(id: string): number | undefined {
  const result = engine.resume(id);
  after("resume");
  return result.ok ? result.word : undefined;
}

export function ledgerSeek(id: string, word: number): void {
  engine.seek(id, word);
  after("seek");
}

/** The read's last chunk played to its end. */
export function ledgerEnded(id: string): void {
  engine.end(id);
  after("end");
}

/** The session was stopped, cancelled or replaced. */
export function ledgerStopped(id: string): void {
  const session = engine.get(id);
  if (session && session.state !== "ended" && session.state !== "parked" && session.state !== "queued") engine.esc(id);
  after("stopped");
}

export function ledgerStopAll(): void {
  engine.stopAll();
  after("stop-all");
}

let previousProbe: () => boolean = () => false;
/** The daemon tells the ledger whether a previous narration exists (its history ring). */
export function setPreviousReadProbe(probe: () => boolean): void { previousProbe = probe; }

/** "Previous read": the session on screen is held off screen at its word. */
export function ledgerPreviousHold(word?: number): void {
  engine.previous(word);
  after("previous-hold");
}

/** The replay is over: the held read returns paused at its word, or ends when it was superseded. */
export function ledgerPreviousReturn(dropped: boolean): void {
  if (dropped) engine.dropPrevious();
  else engine.previousReturn();
  after(dropped ? "previous-drop" : "previous-return");
}

export function ledgerAskBegin(word?: number): { id: string; word: number } | undefined {
  const result = engine.askBegin(word);
  after("ask-begin");
  return result.ok && result.id !== undefined ? { id: result.id, word: result.word ?? 0 } : undefined;
}

export function ledgerAskPromptSkipped(): void { engine.askPromptSkipped(); after("prompt-skipped"); }
export function ledgerMicOpen(): void {
  // A prompt that never reported its exit (text-only, refused) cannot hold the speaker in the ledger.
  if (engine.ask === "waiting") engine.askPromptSkipped();
  if (engine.ask === "prompt") { engine.playerExited(ASK_PROMPT_ID); engine.askPromptEnd(); }
  engine.micOpen();
  after("mic-open");
}
export function ledgerCaptureEnd(reason: AskEnd): void { engine.captureEnd(reason); after("capture-end"); }
export function ledgerAskAbort(reason: AskEnd): void { engine.askAbort(reason); after("ask-abort"); }
export function ledgerRecorderExit(): void { engine.recorderExit(); after("recorder-exit"); }

/** Ask end: restore exactly the parked read. Returns what the driver must do with it. */
export function ledgerAskRestore(): AskRestore | undefined {
  if (engine.ask === "capture") engine.captureEnd("cancel");
  if (engine.ask !== "none" && engine.ask !== "closing") engine.askAbort("cancel");
  engine.recorderExit();
  const result = engine.askRestore();
  after("ask-restore");
  return result.ok ? result.restored : undefined;
}

export function ledgerSnapshot(): PlaybackSessionEvent { return snapshotEvent(); }

export function pruneLedger(): void { engine.prune(); }
