/**
 * Asks open right now in this process, for voice_ask_results. Process-local: the daemon sees its own asks; a stdio
 * `mcp-server.ts` process sees only the asks it runs. Holds a question preview and phase, never the answer.
 */
export type OpenAskPhase = "speaking" | "listening" | "transcribing";
export type OpenAsk = { phase: OpenAskPhase; started_at: string; question_preview: string; archive_id?: string };

/** The retained-result rule: the first 80 characters (code points) of the spoken question. */
export function questionPreview(text: string): string {
  return Array.from(text).slice(0, 80).join("");
}

const open = new Set<OpenAskHandle>();

export class OpenAskHandle {
  private record: OpenAsk | null = null;
  private ended = false;
  /** Registers the ask as open (first call) or moves it to the next phase. A no-op once ended. */
  phase(phase: OpenAskPhase, question?: string): void {
    if (this.ended) return;
    this.record ??= { phase, started_at: new Date().toISOString(), question_preview: "" };
    this.record.phase = phase;
    if (question !== undefined) this.record.question_preview = questionPreview(question);
    open.add(this);
  }
  archive(id: string): void {
    if (!this.ended && this.record) this.record.archive_id = id;
  }
  /** Idempotent; after it, the handle can never show the ask as open again. */
  end(): void {
    this.ended = true;
    open.delete(this);
  }
  snapshot(): OpenAsk | null {
    return this.record && !this.ended ? { ...this.record } : null;
  }
}

/** Open asks, newest first. */
export function listOpenAsks(): OpenAsk[] {
  return [...open].map(handle => handle.snapshot()).filter((ask): ask is OpenAsk => ask !== null)
    .sort((a, b) => b.started_at.localeCompare(a.started_at));
}
