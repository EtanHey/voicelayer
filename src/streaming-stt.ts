/**
 * Streaming STT — sends audio chunks to whisper-server during recording.
 *
 * Accumulates 16kHz PCM audio and periodically sends ~3s windows to
 * whisper-server's /inference endpoint. Returns partial transcriptions
 * that the caller broadcasts via socket for live dictation in the Voice Bar.
 *
 * AIDEV-NOTE: This runs IN PARALLEL with VAD — same PCM chunks feed both
 * the VAD (for stop detection) and the streaming STT (for live text).
 * The streaming transcription is "best effort" — errors don't break recording.
 */

import { createWavBuffer } from "./input";
import { transcribeViaServer, ensureServer } from "./whisper-server";
import { broadcast } from "./socket-server";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;

/**
 * Streaming window size in seconds.
 * Larger = more accurate but higher latency. 3s is a good balance.
 */
const WINDOW_SECONDS = 3;
const WINDOW_BYTES = WINDOW_SECONDS * SAMPLE_RATE * BYTES_PER_SAMPLE;

/**
 * Minimum audio to accumulate before sending first chunk.
 * Avoids sending tiny fragments that produce garbage transcriptions.
 */
const MIN_FIRST_CHUNK_SECONDS = 1.5;
const MIN_FIRST_CHUNK_BYTES =
  MIN_FIRST_CHUNK_SECONDS * SAMPLE_RATE * BYTES_PER_SAMPLE;

export interface StreamingSTTSession {
  /** Feed a new PCM chunk (16kHz 16-bit mono). Called from the recording loop. */
  feed(pcmChunk: Uint8Array): void;

  /** Signal that recording has stopped. Flushes remaining audio. */
  stop(): Promise<void>;

  /** Get the accumulated full transcription so far. */
  getText(): string;
}

/**
 * Create a streaming STT session.
 * Starts whisper-server if not already running.
 *
 * @returns A session object, or null if whisper-server is not available.
 */
export async function createStreamingSession(): Promise<StreamingSTTSession | null> {
  let serverPort: number;
  try {
    serverPort = await ensureServer();
  } catch (err) {
    console.error(
      `[voicelayer] Streaming STT unavailable: ${err instanceof Error ? err.message : err}`,
    );
    return null;
  }

  const allChunks: Uint8Array[] = [];
  let totalBytes = 0;
  let lastSentBytes = 0;
  let fullText = "";
  let inflight = false;
  let stopped = false;

  /** Send accumulated audio to whisper-server. */
  async function sendWindow(): Promise<void> {
    if (inflight || stopped) return;
    if (totalBytes <= lastSentBytes) return;

    // Determine what to send: all audio from the start
    // (whisper works better with full context, not just the new window)
    const toSend = totalBytes;
    if (toSend < MIN_FIRST_CHUNK_BYTES && lastSentBytes === 0) return;

    // Snapshot chunks synchronously before any async work
    // (allChunks may grow while we await the HTTP request)
    const chunksSnapshot = [...allChunks];

    inflight = true;
    try {
      // Concatenate snapshot into one buffer
      const pcm = new Uint8Array(toSend);
      let offset = 0;
      for (const chunk of chunksSnapshot) {
        if (offset + chunk.byteLength > toSend) break;
        pcm.set(chunk, offset);
        offset += chunk.byteLength;
      }

      const wav = createWavBuffer(pcm.slice(0, toSend));
      const text = await transcribeViaServer(wav, serverPort);
      lastSentBytes = toSend;

      if (text && text !== fullText) {
        fullText = text;
        broadcast({
          type: "transcription",
          text,
          partial: true,
        });
      }
    } catch (err) {
      // Streaming errors are non-fatal — don't break recording
      console.error(
        `[voicelayer] Streaming STT error: ${err instanceof Error ? err.message : err}`,
      );
    } finally {
      inflight = false;
    }
  }

  return {
    feed(pcmChunk: Uint8Array): void {
      if (stopped) return;
      allChunks.push(pcmChunk);
      totalBytes += pcmChunk.byteLength;

      // Send when we've accumulated enough new audio since last send
      const newBytes = totalBytes - lastSentBytes;
      if (newBytes >= WINDOW_BYTES && !inflight) {
        sendWindow();
      }
    },

    async stop(): Promise<void> {
      stopped = true;
      // Flush: send everything we have
      if (totalBytes > lastSentBytes && !inflight) {
        await sendWindow();
      }
      // Wait for any inflight request to finish (max 10s to avoid hanging)
      const deadline = Date.now() + 10_000;
      while (inflight && Date.now() < deadline) {
        await Bun.sleep(50);
      }
    },

    getText(): string {
      return fullText;
    },
  };
}
