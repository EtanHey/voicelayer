import type { DeadlineClock } from "../../deadline-clock";

export class ManualClock implements DeadlineClock {
  readonly scheduledDelays: number[] = [];
  private time = 0;
  private readonly timers = new Map<() => void, number>();
  now() { return this.time; }
  schedule(callback: () => void, delayMs: number) {
    this.scheduledDelays.push(delayMs);
    this.timers.set(callback, this.time + delayMs);
    return () => { this.timers.delete(callback); };
  }
  advance(delayMs: number) {
    this.time += delayMs;
    for (const [callback, deadline] of this.timers) {
      if (deadline <= this.time) {
        this.timers.delete(callback);
        callback();
      }
    }
  }
  get pendingDelays() { return [...this.timers.values()].map(deadline => deadline - this.time); }
  get pendingTimers() { return this.timers.size; }
}
