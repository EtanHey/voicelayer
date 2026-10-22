/** Monotonic deadlines, with scheduling supplied by the same clock. */
export interface DeadlineClock {
  now(): number;
  schedule(callback: () => void, delayMs: number): () => void;
}

export const systemDeadlineClock: DeadlineClock = {
  now: () => performance.now(),
  schedule(callback, delayMs) {
    const timer = setTimeout(callback, delayMs);
    return () => clearTimeout(timer);
  },
};
