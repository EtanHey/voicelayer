export type UnloadResult =
  | { outcome: "accept"; residency: "not_loaded" }
  | { outcome: "reject"; reason: string };

/** Serializes an explicit unload against server startup and inference. */
export class WhisperLifecycleGate {
  private users = 0;
  private unloading = false;
  private captureRequested = false;
  private release: (() => void) | null = null;
  private cleared: Promise<void> | null = null;

  get isUnloading(): boolean { return this.unloading; }
  get isInUse(): boolean { return this.users > 0; }
  get shouldYieldToCapture(): boolean { return this.unloading && this.captureRequested; }

  yieldToCapture(): void {
    if (this.unloading) this.captureRequested = true;
  }

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
    this.captureRequested = false;
    this.cleared = new Promise<void>((resolve) => { this.release = resolve; });
    try {
      // Recheck after the reservation is established. Future use() calls wait.
      if (isBusy()) return { outcome: "reject", reason: "busy" };
      const residency = await stop();
      if (this.captureRequested) return { outcome: "reject", reason: "capture took priority" };
      return { outcome: "accept", residency };
    } catch (error) {
      return {
        outcome: "reject",
        reason: error instanceof Error ? error.message : String(error),
      };
    } finally {
      this.unloading = false;
      this.captureRequested = false;
      this.cleared = null;
      this.release?.();
      this.release = null;
    }
  }
}

export const whisperLifecycleGate = new WhisperLifecycleGate();
