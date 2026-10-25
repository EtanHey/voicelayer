/**
 * QPRE1: the queue head's prepared first chunk. Synthesized in the background after the current read's
 * synthesis is complete, held in memory and one temp file only, and either transferred exactly once into
 * the read's chunk-0 synthesis or disposed exactly once. Never played, broadcast or saved to history here.
 */
import type { SpeakableText } from "../speakable-text";
import type { LongReadChunk } from "./long-read";

export interface PreparedChunk {
  chunk: LongReadChunk;
  voice: string;
  engine: string;
  spokenText?: string;
  /** Clone chunks carry their speakable projection for alignment, as on-demand synthesis does. */
  projection?: SpeakableText;
}

export class PreparedReadStart {
  private state: "held" | "transferred" | "disposed" = "held";

  constructor(
    /** Display chunk, resolved profile and spoken projection the audio was made from. */
    private readonly identity: string,
    private readonly prepared: PreparedChunk,
    private readonly release: (chunk: LongReadChunk) => void,
  ) {}

  /** Transfer to the read's start when it would synthesize exactly this audio; a mismatch is disposed. */
  take(identity: string): PreparedChunk | undefined {
    if (this.state !== "held") return undefined;
    if (identity !== this.identity) { this.dispose(); return undefined; }
    this.state = "transferred";
    return this.prepared;
  }

  /** Idempotent; a no-op once the read owns the audio. */
  dispose(): void {
    if (this.state !== "held") return;
    this.state = "disposed";
    this.release(this.prepared.chunk);
  }
}
