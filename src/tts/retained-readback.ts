import { randomUUID } from "node:crypto";
import { copyFileSync, existsSync, unlinkSync } from "node:fs";
import { ttsFilePath } from "../paths";
import type { PlaybackMetadata } from "../tts";

export interface RetainedChunk { file: string; metadata: PlaybackMetadata }
/** One displayed utterance, independent of played-range history and ring-slot rotation. */
export class RetainedReadback {
  private owner?: string;
  private identity = randomUUID();
  private chunks = new Map<number, RetainedChunk>();
  private counter = 0;
  private readers = 0;
  private retired: string[] = [];

  remember(file: string, metadata: PlaybackMetadata, jobID: string): string {
    const owner = metadata.longRead?.id ?? jobID;
    if (owner !== this.owner) {
      this.retired.push(...[...this.chunks.values()].map(c => c.file));
      this.chunks.clear(); this.owner = owner; this.identity = randomUUID(); this.clean();
    }
    const index = metadata.longRead?.chunk_index ?? 0;
    if (this.chunks.has(index)) return this.identity;
    const retained = ttsFilePath(process.pid, ++this.counter).replace(".mp3", `.${this.identity}.readback.mp3`);
    try {
      copyFileSync(file, retained);
      const { onStarted, onCompleted, onQueued, onAlignedWords, nextState, seekSliceFile, localOffsetMs, isSeek, getUtteranceDurationMs, ...facts } = metadata;
      this.chunks.set(index, { file: retained, metadata: { ...facts,
        utteranceDurationMs: metadata.getUtteranceDurationMs?.() ?? metadata.utteranceDurationMs } });
    } catch { try { unlinkSync(retained); } catch {} } // Failed copies stay unavailable.
    return this.identity;
  }

  /** The span a readback seek can reach right now; 0 when `acquire` would refuse it. */
  seekableMs(owner?: string): number {
    return this.replayable(owner)?.reduce((sum, [, c]) => sum + c.metadata.durationMs!, 0) ?? 0;
  }

  acquire(owner?: string): { chunks: RetainedChunk[]; release(): void } | undefined {
    const chunks = this.replayable(owner);
    if (!chunks) return;
    this.readers++;
    let released = false;
    return { chunks: chunks.map(([, c]) => c), release: () => {
      if (released) return; released = true; this.readers--; this.clean();
    } };
  }

  private replayable(owner?: string): [number, RetainedChunk][] | undefined {
    if (!owner || owner !== this.identity) return;
    const chunks = [...this.chunks.entries()].sort(([a], [b]) => a - b);
    if (!chunks.length || chunks.some(([i, c], n) => i !== n || !existsSync(c.file) || !Number.isFinite(c.metadata.durationMs) || !(c.metadata.durationMs! > 0))) return;
    return chunks;
  }

  /** Called only at process exit; no playback can resume in this process. */
  dispose(): void {
    for (const file of [...this.retired, ...[...this.chunks.values()].map(c => c.file)]) {
      try { unlinkSync(file); } catch {}
    }
    this.retired = []; this.chunks.clear();
  }

  private clean(): void {
    if (this.readers) return;
    for (const file of this.retired.splice(0)) { try { unlinkSync(file); } catch {} }
  }
}
