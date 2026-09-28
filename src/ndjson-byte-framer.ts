/** Maximum accepted NDJSON line size, excluding LF. Larger than the MCP daemon's 10 MiB frame limit. */
export const MAX_NDJSON_LINE_BYTES = 16 * 1024 * 1024;

/** Holds undecoded bytes until LF, so a read can end inside a UTF-8 character. */
export class NDJSONByteFramer {
  private pending: Buffer[] = [];
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
        this.pending = [];
        this.pendingBytes = 0;
        this.overflowed = true;
        return { lines, overflow: true };
      }
      if (part.length > 0) {
        // Copy only retained bytes; a tiny tail must not pin a large socket chunk.
        this.pending.push(Buffer.from(part));
        this.pendingBytes += part.length;
      }
      if (newline < 0) break;

      if (this.pendingBytes > 0) {
        lines.push(Buffer.concat(this.pending, this.pendingBytes).toString("utf8"));
      }
      this.pending = [];
      this.pendingBytes = 0;
      start = newline + 1;
    }
    return { lines, overflow: false };
  }
}
