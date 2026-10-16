import type { QueuedPlaybackHandle } from "./playback-lifecycle";

/** Separate from prompt synthesis, capture startup and VoiceBar's 2 s ACK. */
export const PLAYER_EXIT_TIMEOUT_MS = 5_000;

export async function boundedPlaybackWait<T>(work: Promise<T>, budgetMs: number, stage: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([work, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`${stage} timed out after ${budgetMs}ms`)), budgetMs);
    })]);
  } finally { clearTimeout(timer); }
}

export async function waitForPlayerExit(playbacks: readonly QueuedPlaybackHandle[]): Promise<void> {
  const exited = Promise.allSettled(playbacks.map(handle => handle.playerExited)).then(results => {
    const failure = results.find(result => result.status === "rejected");
    if (failure) throw new Error("Player exit could not be confirmed", { cause: failure.reason });
  });
  await boundedPlaybackWait(exited, PLAYER_EXIT_TIMEOUT_MS, "Player exit confirmation");
}
