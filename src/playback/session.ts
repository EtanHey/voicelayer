/**
 * Lane B (2.4): ONE explicit playback-session machine for Option+F5 reads, voice_speak and
 * voice_ask narration, and the teleprompter. formal/playback-session/PlaybackSession.tla is
 * the model; every state, event and invariant here has the same name there.
 *
 * Positions are WORD INDICES owned by the session. A resume lands on the word stored at
 * pause; it is never re-derived from a client clock or from a re-synthesised clip.
 *
 * The engine is pure and synchronous: the player driver (PlaybackQueueManager in tts.ts)
 * reports what happened and asks what to do; nothing here spawns, waits or broadcasts.
 */

export type SessionState = "queued" | "preparing" | "playing" | "paused" | "seeking" | "parked" | "ended";
export type SessionKind = "read" | "speak";
export type PauseOwner = "user" | "f5" | "ask";
export type AskPhase = "none" | "waiting" | "prompt" | "capturewait" | "capture" | "closing";
export type AskEnd = "answer" | "fail" | "cancel" | "timeout";

/** The ask prompt is audio too; it holds the speaker under this id. */
export const ASK_PROMPT_ID = "voice-ask-prompt";

const LIVE: ReadonlySet<SessionState> = new Set(["preparing", "playing", "paused", "seeking", "parked"]);
const POSITIONED: ReadonlySet<SessionState> = new Set(["preparing", "playing", "paused", "seeking"]);

export interface PlaybackSession {
  readonly id: string;
  readonly kind: SessionKind;
  state: SessionState;
  /** The word the audio is on (or will start from). */
  cursor: number;
  wordCount: number;
  /** The word stored at pause/park; a resume lands here. */
  pausedAt?: number;
  pauseOwner?: PauseOwner;
  /** Where the last resume landed (cleared by the next pause or seek). */
  resumedAt?: number;
  seekTo?: number;
  generation: number;
}

export interface SessionTransition {
  event: string;
  id?: string;
  from?: SessionState;
  to?: SessionState;
  word?: number;
}

export type EngineResult =
  | { ok: true; word?: number; id?: string; state?: SessionState }
  | { ok: false; reason: string };

export interface AskRestore {
  id: string;
  state: "paused" | "preparing";
  word: number;
}

const ok = (extra: Omit<Extract<EngineResult, { ok: true }>, "ok"> = {}): EngineResult => ({ ok: true, ...extra });
const no = (reason: string): EngineResult => ({ ok: false, reason });

export class PlaybackSessionEngine {
  private readonly sessions = new Map<string, PlaybackSession>();
  /** Reads in the order they first started; "previous read" walks this. */
  private readonly history: string[] = [];
  readonly players = new Set<string>();
  readonly exiting = new Set<string>();
  readonly preparing = new Set<string>();
  /** The teleprompter's word (the session on screen). */
  tele = 0;
  ask: AskPhase = "none";
  parked?: { id: string; from: "paused" | "playing" };
  mic = false;
  recorder = false;
  readonly log: SessionTransition[] = [];
  private readonly maxLog: number;

  constructor(options: { maxLog?: number } = {}) {
    this.maxLog = options.maxLog ?? 256;
  }

  get(id: string): Readonly<PlaybackSession> | undefined { return this.sessions.get(id); }

  /** The session that owns the screen: positioned or parked. */
  live(): Readonly<PlaybackSession> | undefined {
    for (const session of this.sessions.values()) if (LIVE.has(session.state)) return session;
    return undefined;
  }

  /** Sessions on screen (positioned), for the driver's conformance checks. */
  positionedSessions(): Readonly<PlaybackSession>[] {
    return [...this.sessions.values()].filter(session => POSITIONED.has(session.state));
  }

  private positioned(): PlaybackSession | undefined {
    for (const session of this.sessions.values()) if (POSITIONED.has(session.state)) return session;
    return undefined;
  }

  private quiet(): boolean { return this.players.size === 0 && this.exiting.size === 0; }

  private record(event: string, session?: PlaybackSession, from?: SessionState): void {
    this.log.push({ event, ...(session ? { id: session.id, from, to: session.state, word: session.cursor } : {}) });
    if (this.log.length > this.maxLog) this.log.splice(0, this.log.length - this.maxLog);
  }

  private leave(id: string): void {
    if (this.players.delete(id)) this.exiting.add(id);
  }

  private move(session: PlaybackSession, to: SessionState, event: string): void {
    const from = session.state;
    session.state = to;
    session.generation++;
    if (to !== "preparing") this.preparing.delete(session.id);
    if (to !== "playing") this.leave(session.id);
    this.record(event, session, from);
  }

  /** Start: a new session replaces whatever positioned session is on screen. Refused during an ask. */
  begin(id: string, kind: SessionKind, wordCount: number): EngineResult {
    if (this.ask !== "none") return no("ask in progress");
    if (id === this.previousHeld) return no("held by previous read");
    const existing = this.sessions.get(id);
    if (existing && LIVE.has(existing.state)) return ok({ id, state: existing.state });
    for (const other of this.sessions.values()) {
      if (other.id !== id && POSITIONED.has(other.state)) this.move(other, "ended", "replaced");
    }
    const session: PlaybackSession = existing ?? { id, kind, state: "queued", cursor: 0, wordCount, generation: 0 };
    session.wordCount = Math.max(session.wordCount, wordCount);
    session.cursor = 0;
    session.pausedAt = undefined;
    session.resumedAt = undefined;
    this.sessions.set(id, session);
    if (kind === "read" && !this.history.includes(id)) this.history.push(id);
    this.move(session, "preparing", "start");
    this.preparing.add(id);
    this.tele = 0;
    return ok({ id, state: "preparing", word: 0 });
  }

  /** More words became known (a later chunk synthesised). */
  extend(id: string, wordCount: number): void {
    const session = this.sessions.get(id);
    if (session) session.wordCount = Math.max(session.wordCount, wordCount);
  }

  /** The prepared player may start only when the speaker is quiet and the mic is closed. */
  canStart(id: string): boolean {
    const session = this.sessions.get(id);
    return session?.state === "preparing" && this.quiet() && !this.mic && !this.recorder;
  }

  /** Ready: the player started. A preparation whose session moved on is dropped (NoZombie). */
  ready(id: string): EngineResult {
    const session = this.sessions.get(id);
    if (!session || session.state !== "preparing") {
      this.preparing.delete(id);
      return no(session ? `session is ${session.state}` : "unknown session");
    }
    if (!this.quiet()) return no("speaker busy");
    if (this.mic || this.recorder) return no("mic open");
    this.preparing.delete(id);
    this.players.add(id);
    this.move(session, "playing", "ready");
    return ok({ word: session.cursor });
  }

  /** Advance: the player reached `word`. The teleprompter follows through `teleprompter()`. */
  word(id: string, word: number): void {
    const session = this.sessions.get(id);
    if (!session || session.state !== "playing") return;
    session.cursor = clampWord(word, session.wordCount);
  }

  /** TeleSync: the teleprompter now shows `word`. With an id, only for that session while it is on screen. */
  teleprompter(word: number, id?: string): void {
    if (id !== undefined && !POSITIONED.has(this.sessions.get(id)?.state ?? "ended")) return;
    this.tele = Math.max(0, Math.trunc(word));
  }

  /** End: the player played past its last word (model End: only a playing session ends). */
  end(id: string): EngineResult {
    const session = this.sessions.get(id);
    if (!session || session.state !== "playing") return no(session ? `session is ${session.state}` : "unknown session");
    session.cursor = session.wordCount;
    this.move(session, "ended", "end");
    return ok();
  }

  /** Reap: a player process exited. */
  playerExited(id: string): void {
    this.players.delete(id);
    this.exiting.delete(id);
  }

  /** Pause at `word` (the word the audio is on). From playing or preparing (CLICK2). */
  pause(id: string, word: number, owner: PauseOwner = "user"): EngineResult {
    const session = this.sessions.get(id);
    if (!session) return no("unknown session");
    if (session.state === "paused") {
      if (owner === "user" && session.pauseOwner === "f5") session.pauseOwner = "user";
      return ok({ word: session.pausedAt ?? session.cursor, state: "paused" });
    }
    if (session.state !== "playing" && session.state !== "preparing") return no(`session is ${session.state}`);
    const at = clampWord(word, session.wordCount);
    session.cursor = at;
    session.pausedAt = at;
    session.pauseOwner = owner;
    session.resumedAt = undefined;
    this.move(session, "paused", "pause");
    return ok({ word: at, state: "paused" });
  }

  /** Resume lands on the stored word, never earlier (ResumeExact). */
  resume(id: string): EngineResult {
    const session = this.sessions.get(id);
    if (!session) return no("unknown session");
    if (session.state !== "paused") return no(`session is ${session.state}`);
    if (this.ask !== "none") return no("ask in progress");
    const to = session.pausedAt ?? session.cursor;
    session.cursor = to;
    session.resumedAt = to;
    session.pauseOwner = undefined;
    this.move(session, "preparing", "resume");
    this.preparing.add(id);
    this.tele = to;
    return ok({ word: to, state: "preparing" });
  }

  /** A chunk boundary inside one read: the next chunk's player continues the same session (logged, generation bumped). */
  nextChunk(id: string): EngineResult {
    const session = this.sessions.get(id);
    if (!session || session.state !== "playing") return no(session ? `session is ${session.state}` : "unknown session");
    this.move(session, "preparing", "next-chunk");
    // The previous chunk's player has exited (the driver spawns only then): nothing is left exiting.
    this.exiting.delete(id);
    this.preparing.add(id);
    return ok({ word: session.cursor });
  }

  /** Seek to a word from a playing read. */
  seek(id: string, to: number): EngineResult {
    const session = this.sessions.get(id);
    if (!session || session.state !== "playing") return no(session ? `session is ${session.state}` : "unknown session");
    session.seekTo = clampWord(to, Math.max(0, session.wordCount - 1));
    this.move(session, "seeking", "seek");
    return ok({ word: session.seekTo });
  }

  seekDone(id: string): EngineResult {
    const session = this.sessions.get(id);
    if (!session || session.state !== "seeking") return no(session ? `session is ${session.state}` : "unknown session");
    session.cursor = session.seekTo ?? session.cursor;
    session.resumedAt = undefined;
    session.pausedAt = undefined;
    this.move(session, "preparing", "seek-done");
    this.preparing.add(id);
    this.tele = session.cursor;
    return ok({ word: session.cursor });
  }

  /** Esc stops the positioned session on screen (a resumed one included). During an ask, Esc aborts the ask. */
  esc(id?: string): EngineResult {
    if (this.ask !== "none") return this.askAbort("cancel");
    const session = id ? this.sessions.get(id) : this.positioned();
    if (!session || !POSITIONED.has(session.state)) return no("nothing on screen");
    this.move(session, "ended", "esc");
    return ok({ id: session.id });
  }

  /** The read played before the one on screen, if any. */
  previousOf(id: string): string | undefined {
    const index = this.history.indexOf(id);
    return index > 0 ? this.history[index - 1] : undefined;
  }

  /** The read held off screen by "previous read", if any. */
  previousHeld?: string;

  /**
   * Previous read: the session on screen is held off screen at its exact word (state `queued`,
   * its word kept) while the driver plays the previous narration from its first word as a new
   * session. previousReturn() brings it back PAUSED at that word (model PreviousRead/PrevReturn).
   */
  previous(driverWord?: number): EngineResult {
    if (this.ask !== "none") return no("ask in progress");
    if (this.previousHeld) return no("previous read in progress");
    const current = this.positioned();
    if (!current) return no("nothing on screen");
    const at = current.state === "paused" ? current.pausedAt ?? current.cursor
      : driverWord !== undefined ? clampWord(driverWord, current.wordCount)
        : current.state === "seeking" ? current.seekTo ?? current.cursor
          : current.cursor;
    current.cursor = at;
    current.pausedAt = at;
    current.resumedAt = undefined;
    this.previousHeld = current.id;
    this.move(current, "queued", "previous-hold");
    this.tele = 0;
    return ok({ id: current.id, word: at, state: "queued" });
  }

  /** The held read was superseded by a new read: it ends without coming back. */
  dropPrevious(): void {
    const id = this.previousHeld;
    this.previousHeld = undefined;
    const session = id ? this.sessions.get(id) : undefined;
    if (session && session.state === "queued") this.move(session, "ended", "previous-drop");
  }

  /** The previous narration is over (ended or stopped): the held read returns paused at its word. */
  previousReturn(): EngineResult {
    const id = this.previousHeld;
    if (!id) return no("nothing held");
    if (this.ask !== "none") return no("ask in progress");
    if (this.positioned()) return no("previous read still on screen");
    this.previousHeld = undefined;
    const session = this.sessions.get(id);
    if (!session || session.state !== "queued") return no("held read ended");
    session.cursor = session.pausedAt ?? session.cursor;
    session.pauseOwner = "user";
    this.move(session, "paused", "previous-return");
    this.tele = session.cursor;
    return ok({ id, word: session.cursor, state: "paused" });
  }

  /**
   * voice_ask preempts: the positioned read is parked at its exact word, keeping whether it was paused.
   * `only` names the session the driver actually parked (null: it parked nothing), so the engine never records a park
   * the player does not honour (statechart gap 1). Omitted, the engine parks whatever is positioned (the model's rule).
   */
  askBegin(driverWord?: number, only?: string | null): EngineResult {
    if (this.ask !== "none") return no("ask in progress");
    this.ask = "waiting";
    this.record("ask-begin");
    const named = only === undefined ? this.positioned() : only === null ? undefined : this.sessions.get(only);
    const session = named && POSITIONED.has(named.state) ? named : undefined;
    if (!session) return ok();
    const from = session.state === "paused" ? "paused" : "playing";
    // A user pause keeps its stored word. Otherwise the driver names the word the audio is on.
    const word = session.state === "paused" ? session.pausedAt ?? session.cursor
      : driverWord !== undefined ? clampWord(driverWord, session.wordCount)
        : session.state === "seeking" ? session.seekTo ?? session.cursor
          : session.cursor;
    session.pausedAt = word;
    session.cursor = word;
    session.resumedAt = undefined;
    this.parked = { id: session.id, from };
    this.move(session, "parked", "ask-park");
    return ok({ id: session.id, word, state: "parked" });
  }

  canStartPrompt(): boolean { return this.ask === "waiting" && this.quiet() && !this.mic; }

  askPromptStart(): EngineResult {
    if (!this.canStartPrompt()) return no(this.ask !== "waiting" ? `ask is ${this.ask}` : "speaker busy");
    this.ask = "prompt";
    this.players.add(ASK_PROMPT_ID);
    this.tele = 0;
    this.record("ask-prompt-start");
    return ok();
  }

  askPromptEnd(): EngineResult {
    if (this.ask !== "prompt") return no(`ask is ${this.ask}`);
    this.ask = "capturewait";
    this.leave(ASK_PROMPT_ID);
    this.record("ask-prompt-end");
    return ok();
  }

  /** A text-only prompt (synthesis failed) goes straight to capture. */
  askPromptSkipped(): EngineResult {
    if (this.ask !== "waiting") return no(`ask is ${this.ask}`);
    this.ask = "capturewait";
    this.record("ask-prompt-skipped");
    return ok();
  }

  canOpenMic(): boolean { return this.ask === "capturewait" && this.quiet(); }

  micOpen(): EngineResult {
    if (!this.canOpenMic()) return no(this.ask !== "capturewait" ? `ask is ${this.ask}` : "speaker busy");
    this.ask = "capture";
    this.mic = true;
    this.recorder = true;
    this.record("mic-open");
    return ok();
  }

  /** Capture end (answer, failed capture, cancel, timeout): the mic closes first. */
  captureEnd(_reason: AskEnd = "answer"): EngineResult {
    if (this.ask !== "capture") return no(`ask is ${this.ask}`);
    this.ask = "closing";
    this.mic = false;
    this.record("capture-end");
    return ok();
  }

  /** The ask failed or was cancelled before or during its prompt or capture. */
  askAbort(_reason: AskEnd = "fail"): EngineResult {
    if (this.ask === "none" || this.ask === "closing") return no(`ask is ${this.ask}`);
    this.ask = "closing";
    this.mic = false;
    this.leave(ASK_PROMPT_ID);
    this.record("ask-abort");
    return ok();
  }

  recorderExit(): void {
    if (this.mic) return;
    if (this.recorder) this.record("recorder-exit");
    this.recorder = false;
  }

  /** Ask end restores exactly the parked read to its exact word, in the state it had. Waits for the recorder. */
  askRestore(): { ok: true; restored?: AskRestore } | { ok: false; reason: string } {
    if (this.ask !== "closing") return { ok: false, reason: `ask is ${this.ask}` };
    if (this.recorder) return { ok: false, reason: "recorder still running" };
    const parked = this.parked;
    this.ask = "none";
    this.parked = undefined;
    this.record("ask-end");
    if (!parked) return { ok: true };
    const session = this.sessions.get(parked.id);
    if (!session || session.state !== "parked") return { ok: true };
    const word = session.pausedAt ?? session.cursor;
    session.cursor = word;
    this.tele = word;
    if (parked.from === "paused") {
      session.pauseOwner = "user";
      this.move(session, "paused", "ask-restore-paused");
      return { ok: true, restored: { id: session.id, state: "paused", word } };
    }
    session.resumedAt = word;
    this.move(session, "preparing", "ask-restore");
    this.preparing.add(session.id);
    return { ok: true, restored: { id: session.id, state: "preparing", word } };
  }

  /** Stop: every positioned session ends and an ask in flight closes, together with the read it parked: Stop
   * means stop (the paused-ask stack's W1 "stopped" contract; its daemon tests pin it). */
  stopAll(): void {
    for (const session of this.sessions.values()) if (POSITIONED.has(session.state)) this.move(session, "ended", "stop");
    for (const id of this.players) this.exiting.add(id);
    this.players.clear();
    const parked = this.parked && this.sessions.get(this.parked.id);
    if (parked?.state === "parked") this.move(parked, "ended", "stop");
    this.parked = undefined;
    this.mic = false;
    if (this.ask !== "none" && this.ask !== "closing") this.ask = "closing";
    this.record("stop");
  }

  /** Drop ended sessions beyond the read history so a long-lived daemon stays bounded. */
  prune(keepReads = 8): void {
    while (this.history.length > keepReads) {
      const id = this.history.shift()!;
      if (this.sessions.get(id)?.state === "ended") this.sessions.delete(id);
    }
    for (const [id, session] of this.sessions) {
      if (session.state === "ended" && !this.history.includes(id)) this.sessions.delete(id);
    }
  }

  /** The TLA+ invariants over the current state. Empty means healthy. */
  violations(): string[] {
    const found: string[] = [];
    const sessions = [...this.sessions.values()];
    for (const session of sessions) {
      if (session.resumedAt !== undefined && session.pausedAt !== undefined && session.resumedAt !== session.pausedAt) {
        found.push(`ResumeExact: ${session.id} resumed at word ${session.resumedAt}, paused at ${session.pausedAt}`);
      }
    }
    if (this.players.size + this.exiting.size > 1) found.push(`OneAudible: ${[...this.players, ...this.exiting].join(", ")}`);
    const parked = sessions.filter(session => session.state === "parked");
    if (parked.length > 1) found.push(`AskParksOne: ${parked.length} parked`);
    if (this.parked && this.sessions.get(this.parked.id)?.state !== "parked") found.push("AskParksOne: parked id is not parked");
    if (this.ask === "none" && parked.length > 0) found.push(`AskParksOne: ${parked[0].id} left parked after the ask`);
    if ((this.mic || this.recorder) && !this.quiet()) found.push("MicExclusive: audio while the mic or recorder is open");
    for (const session of sessions) {
      if (POSITIONED.has(session.state) && Math.abs(this.tele - session.cursor) > 1) {
        found.push(`TeleTracksAudio: teleprompter word ${this.tele}, audio word ${session.cursor}`);
      }
    }
    if (sessions.filter(session => LIVE.has(session.state)).length > 1) found.push("OneLiveSession: more than one live session");
    for (const id of this.players) {
      if (id === ASK_PROMPT_ID ? this.ask !== "prompt" : this.sessions.get(id)?.state !== "playing") found.push(`NoZombie: ${id}`);
    }
    return found;
  }
}

function clampWord(word: number, max: number): number {
  if (!Number.isFinite(word)) return 0;
  return Math.min(Math.max(0, Math.trunc(word)), Math.max(0, max));
}

/** How far a client clock may differ from the daemon's own player clock and still be trusted. */
export const PAUSE_CLIENT_TOLERANCE_MS = 750;

/**
 * Etan's "pause jumps back to 0:00" (QA 2026-11-08): the client's teleprompter clock was trusted
 * as the pause position. VoiceBar's clock reads 0 while it thinks a read is preparing (between
 * chunks, right after a resume), and a chunk-local value minus the chunk start goes negative;
 * both rewound the read to the chunk's first word.
 *
 * The daemon's player clock is where the audio is. A client clock refines it only BACK, by at most
 * the tolerance (it follows what was heard); a client clock ahead of the player, or far behind it,
 * is overruled. The pause word is the last word whose start that position reached.
 */
export function resolvePauseCursorMs(input: {
  clientMs?: number;
  daemonMs?: number;
  durationMs?: number;
  toleranceMs?: number;
}): { cursorMs: number; source: "client" | "daemon" | "none" } {
  const tolerance = input.toleranceMs ?? PAUSE_CLIENT_TOLERANCE_MS;
  const finite = (value?: number) => value !== undefined && Number.isFinite(value) ? value : undefined;
  const client = finite(input.clientMs);
  const daemon = finite(input.daemonMs);
  const bound = (value: number) => Math.round(Math.min(Math.max(0, value), input.durationMs ?? Infinity));
  if (client === undefined) return daemon === undefined ? { cursorMs: 0, source: "none" } : { cursorMs: bound(daemon), source: "daemon" };
  // #818 review: the word comes from where the audio actually is. The daemon's player clock is that; a client clock
  // may refine it BACK within the tolerance (it follows what was heard), never ahead of it, never far behind it.
  if (daemon !== undefined && (client < daemon - tolerance || client > daemon)) return { cursorMs: bound(daemon), source: "daemon" };
  return { cursorMs: bound(client), source: "client" };
}

/** Playback speed steps for the teleprompter's speed control. 1× is a real step, not a label. */
export const PLAYBACK_SPEEDS = [0.75, 1, 1.25, 1.5, 2] as const;
export type PlaybackSpeed = (typeof PLAYBACK_SPEEDS)[number];

export function isPlaybackSpeed(value: unknown): value is PlaybackSpeed {
  return typeof value === "number" && (PLAYBACK_SPEEDS as readonly number[]).includes(value);
}

export function nextPlaybackSpeed(current: number): PlaybackSpeed {
  const index = PLAYBACK_SPEEDS.findIndex(speed => speed === current);
  return PLAYBACK_SPEEDS[(index + 1) % PLAYBACK_SPEEDS.length] ?? 1;
}
