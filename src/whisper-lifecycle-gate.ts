export type UnloadResult =
  | { outcome: "accept"; residency: "not_loaded" }
  | { outcome: "reject"; reason: string };

/** Serializes an explicit unload against server startup and inference. */
export class WhisperLifecycleGate {
  private users = 0;
  private unloading = false;
  private release: (() => void) | null = null;
  private cleared: Promise<void> | null = null;

  get isUnloading(): boolean { return this.unloading; }

  async use<T>(work: () => Promise<T>): Promise<T> {
    while (this.cleared) await this.cleared;
    this.users++;
    try {
      return await work();
    } finally {
      this.users--;
    }
  }

  async unload(
    isBusy: () => boolean,
    stop: () => Promise<"not_loaded">,
  ): Promise<UnloadResult> {
    if (this.unloading || this.users > 0 || isBusy()) {
      return { outcome: "reject", reason: "busy" };
    }
    this.unloading = true;
    this.cleared = new Promise<void>((resolve) => { this.release = resolve; });
    try {
      // Recheck after the reservation is established. Future use() calls wait.
      if (isBusy()) return { outcome: "reject", reason: "busy" };
      return { outcome: "accept", residency: await stop() };
    } catch (error) {
      return {
        outcome: "reject",
        reason: error instanceof Error ? error.message : String(error),
      };
    } finally {
      this.unloading = false;
      this.cleared = null;
      this.release?.();
      this.release = null;
    }
  }
}

export const whisperLifecycleGate = new WhisperLifecycleGate();
