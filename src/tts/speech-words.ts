import type { AlignedWordBoundary, SpeechWordsEvent, WordBoundary } from "../socket-protocol";
import type { SeekResult } from "./long-read";
import { displayTokens } from "./display-tokens";

/** One utterance owns its synthesized prefix and its retry receipts. */
export class SpeechWordTimeline {
  private chunks = new Map<number, { duration: number; words: SpeechWordsEvent["words"]; approximate: boolean }>();
  private receipts = new Map<string, { wordIndex: number; result: SeekResult }>();
  constructor(readonly utteranceId: string) {}

  update(index: number, text: string, durationMs: number, boundaries: WordBoundary[] = [], aligned: AlignedWordBoundary[] = []): SpeechWordsEvent {
    const tokens = displayTokens(text);
    const duration = Number.isFinite(durationMs) && durationMs > 0 ? durationMs : Math.max(1, tokens.length * 300);
    let approximate = false;
    let previousStart = 0;
    const measured = tokens.map((token, i) => {
      const alignment = aligned.find(word => word.word_index === i && word.text === token[0]);
      const boundary = boundaries[i]?.text === token[0] ? boundaries[i] : undefined;
      const start = alignment?.offset_ms ?? boundary?.offset_ms;
      const length = alignment?.duration_ms ?? boundary?.duration_ms;
      if (start !== undefined && start !== null && Number.isFinite(start) && start >= previousStart && start < duration &&
          length !== undefined && length !== null && Number.isFinite(length) && length > 0) {
        previousStart = start;
        approximate ||= alignment?.estimated === true;
        return { text: token[0], startMs: start, endMs: Math.min(duration, start + length) };
      }
      approximate = true;
      return undefined;
    });
    const words = tokens.map((token, i) => {
      const word = measured[i];
      if (word) return word;
      const leftIndex = measured.findLastIndex((value, index) => index < i && value !== undefined);
      const rightIndex = measured.findIndex((value, index) => index > i && value !== undefined);
      const to = measured[rightIndex]?.startMs ?? duration;
      const from = Math.min(measured[leftIndex]?.endMs ?? 0, to);
      const count = (rightIndex < 0 ? tokens.length : rightIndex) - leftIndex - 1;
      return { text: token[0], startMs: from + (to - from) * (i - leftIndex - 1) / count,
        endMs: from + (to - from) * (i - leftIndex) / count };
    });
    this.chunks.set(index, { duration, words, approximate });
    return this.event(index);
  }

  private event(index: number): SpeechWordsEvent {
    let startMs = 0, wordOffset = 0;
    for (let i = 0; i < index; i++) {
      const chunk = this.chunks.get(i);
      if (!chunk) throw new Error("Speech timings must form a synthesized prefix");
      startMs += chunk.duration; wordOffset += chunk.words.length;
    }
    const chunk = this.chunks.get(index)!;
    return { type: "speech_words", utteranceId: this.utteranceId, wordOffset, approximate: chunk.approximate,
      words: chunk.words.map(word => ({ ...word, startMs: startMs + word.startMs, endMs: startMs + word.endMs })) };
  }

  seek(wordIndex: number, perform: (offsetMs: number) => SeekResult, commandId?: string): SeekResult {
    const receipt = commandId ? this.receipts.get(commandId) : undefined;
    if (receipt) return receipt.wordIndex === wordIndex ? receipt.result : { outcome: "reject", reason: "seek id reused" };
    let offset = 0, remaining = wordIndex;
    for (let i = 0; i < this.chunks.size; i++) {
      const chunk = this.chunks.get(i);
      if (!chunk) break;
      if (remaining < chunk.words.length) {
        const result = perform(offset + chunk.words[remaining].startMs);
        if (commandId && result.outcome === "accept") {
          if (this.receipts.size >= 32) this.receipts.delete(this.receipts.keys().next().value!);
          this.receipts.set(commandId, { wordIndex, result });
        }
        return result;
      }
      offset += chunk.duration; remaining -= chunk.words.length;
    }
    return { outcome: "reject", reason: "word timing unavailable" };
  }
}
