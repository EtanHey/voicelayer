import { Worker } from "node:worker_threads";
import type { SpeakArchiveContext } from "./speak-archive";
import type { SpeechState } from "./speech-state";
export type ArchiveWrite =
  | { kind: "init"; text: string; context?: SpeakArchiveContext }
  | { kind: "move"; to: SpeechState; reason: string | null; at: string }
  | { kind: "start" | "end"; at: string }
  | { kind: "audio"; file: string; duration_ms: number | null; generated?: { text: string; voice: string; profile: string; engine: string; index: number; generated_at: string } };
export type ArchiveReply = { context: SpeakArchiveContext };
/** One owned worker serializes durable writes, away from Bun's playback/control event loop. */
export class SpeechArchiveWriter {
  private worker?: Worker;
  private sequence = 0;
  private pending = new Map<number, { resolve: (reply: ArchiveReply) => void; reject: (error: Error) => void }>();
  write(key: string, operation: ArchiveWrite, context?: SpeakArchiveContext, root = process.env.QA_VOICE_RECORDINGS_DIR): Promise<ArchiveReply> {
    if (!this.worker) {
      const worker = new Worker(new URL("./speech-archive-worker.ts", import.meta.url), { env: process.env });
      this.worker = worker;
      worker.on("message", (message: { id: number; reply?: ArchiveReply; error?: string }) => {
        const { id, reply, error } = message, request = this.pending.get(id);
        this.pending.delete(id);
        if (error) request?.reject(new Error(error)); else if (reply) request?.resolve(reply);
        if (!this.pending.size) worker.unref();
      });
      const failed = () => {
        for (const request of this.pending.values()) request.reject(new Error("ARCHIVE_WORKER_FAILED"));
        this.pending.clear(); worker.terminate(); this.worker = undefined;
      };
      worker.on("error", failed);
      worker.on("exit", () => { if (this.worker === worker) failed(); });
    }
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker!.ref();
      this.worker!.postMessage({ id, key, operation, context, root });
    });
  }
}
export const speechArchiveWriter = new SpeechArchiveWriter();
