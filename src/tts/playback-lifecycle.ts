import type { PlaybackOutcomeEvent } from "../socket-protocol";

/** Omit generation only for an intent that deliberately ends the whole utterance. */
export interface PlaybackScope { id: string; generation?: number }
export interface QueuedPlaybackHandle {
  id: string;
  readonly generation: number;
  /** Logical outcome; cancellation can settle this before a child exits. */
  exited: Promise<PlaybackOutcomeEvent>;
  /** Terminal barrier across every Replay/seek attempt, decoder and player. */
  playerExited: Promise<void>;
  /** Snapshot barrier for a quiesced attempt (future parking freezes admission first). */
  waitForPlayerExit(): Promise<void>;
}

/** Physical ownership survives logical completion and removal from the audible queue.
 * A parked job can remain registered for scoped controls without global Stop enumerating it.
 */
export class PlaybackLifecycle {
  generation = 1;
  private terminal = false;
  private work = new Set<Promise<unknown>>();
  private failure: unknown;
  private failed = false;
  private resolve!: () => void;
  private reject!: (error: unknown) => void;
  readonly playerExited = new Promise<void>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });

  constructor() { void this.playerExited.catch(() => {}); }
  matches(scope: PlaybackScope): boolean { return scope.generation === undefined || scope.generation === this.generation; }
  get hasWork(): boolean { return this.work.size > 0; }
  track<T>(promise: Promise<T>): void {
    this.work.add(promise);
    void promise.then(
      () => { this.work.delete(promise); this.settle(); },
      error => { this.failed = true; this.failure = error; this.work.delete(promise); this.settle(); },
    );
  }
  complete(): void { this.terminal = true; this.settle(); }
  async waitForPlayerExit(): Promise<void> {
    await Promise.all([...this.work]);
    if (this.failed) throw this.failure;
  }
  private settle(): void {
    if (!this.terminal || this.hasWork) return;
    if (this.failed) this.reject(this.failure); else this.resolve();
  }
}
