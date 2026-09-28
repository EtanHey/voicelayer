/** Maximum accepted NDJSON line size, excluding LF. Larger than the MCP daemon's 10 MiB frame limit. */
export const MAX_NDJSON_LINE_BYTES = 16 * 1024 * 1024;

/** Holds undecoded bytes until LF, so a read can end inside a UTF-8 character. */
export class NDJSONByteFramer {
  private pending = Buffer.alloc(0);
  private pendingBytes = 0;
  private overflowed = false;

  constructor(private readonly maxLineBytes = MAX_NDJSON_LINE_BYTES) {
    if (!Number.isSafeInteger(maxLineBytes) || maxLineBytes < 1) {
      throw new RangeError("maxLineBytes must be a positive integer");
    }
  }

  append(raw: Uint8Array): { lines: string[]; overflow: boolean } {
    if (this.overflowed) return { lines: [], overflow: false };

    const lines: string[] = [];
    let start = 0;
    while (start < raw.length) {
      const newline = raw.indexOf(0x0a, start);
      const end = newline < 0 ? raw.length : newline;
      const part = raw.subarray(start, end);
      if (this.pendingBytes + part.length > this.maxLineBytes) {
        this.pending = Buffer.alloc(0);
        this.pendingBytes = 0;
        this.overflowed = true;
        return { lines, overflow: true };
      }
      if (part.length > 0) {
        const needed = this.pendingBytes + part.length;
        if (needed > this.pending.length) {
          // Geometric growth bounds allocations even if a peer sends one byte per read.
          const capacity = Math.min(this.maxLineBytes, Math.max(4096, needed, this.pending.length * 2));
          const next = Buffer.allocUnsafe(capacity);
          this.pending.copy(next, 0, 0, this.pendingBytes);
          this.pending = next;
        }
        this.pending.set(part, this.pendingBytes);
        this.pendingBytes += part.length;
      }
      if (newline < 0) break;

      if (this.pendingBytes > 0) {
        lines.push(this.pending.toString("utf8", 0, this.pendingBytes));
      }
      this.pending = Buffer.alloc(0);
      this.pendingBytes = 0;
      start = newline + 1;
    }
    return { lines, overflow: false };
  }
}
