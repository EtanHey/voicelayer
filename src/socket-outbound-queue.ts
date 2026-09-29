/** Preserve partial Unix-socket writes without re-encoding or reordering frames. */
export const MAX_OUTBOUND_QUEUE_BYTES = 32 * 1024 * 1024;

export interface SocketWriteTarget {
  write(bytes: Uint8Array): number;
  end(): void;
}

export class SocketOutboundQueue {
  private queue: Buffer[] = [];
  private offset = 0;
  private pendingBytes = 0;
  private closed = false;
  private flushing = false;
  private emptyWaiters: Array<() => void> = [];

  constructor(
    private readonly socket: SocketWriteTarget,
    private readonly label: string,
    private readonly maxBytes = MAX_OUTBOUND_QUEUE_BYTES,
    private readonly onFailure?: () => void,
  ) {}

  get queuedBytes(): number { return this.pendingBytes; }

  whenEmpty(): Promise<void> {
    if (this.pendingBytes === 0 || this.closed) return Promise.resolve();
    return new Promise((resolve) => { this.emptyWaiters.push(resolve); });
  }

  enqueue(payload: string | Uint8Array): void {
    if (this.closed) return;
    const bytes = typeof payload === "string" ? Buffer.from(payload, "utf8") : Buffer.from(payload);
    if (bytes.length === 0) return;
    if (bytes.length > this.maxBytes - this.pendingBytes) {
      console.error(`[${this.label}] outbound queue exceeded ${this.maxBytes} bytes; closing connection`);
      this.fail();
      return;
    }
    this.queue.push(bytes);
    this.pendingBytes += bytes.length;
    this.flush();
  }

  drain(): void {
    this.flush();
  }

  close(): void {
    this.closed = true;
    this.queue = [];
    this.offset = 0;
    this.pendingBytes = 0;
    this.resolveEmpty();
  }

  private fail(): void {
    this.close();
    try { this.socket.end(); } catch {}
    this.onFailure?.();
  }

  private flush(): void {
    if (this.closed || this.flushing) return;
    this.flushing = true;
    try {
      while (this.queue.length > 0 && !this.closed) {
        const head = this.queue[0]!;
        const remaining = head.subarray(this.offset);
        const written = this.socket.write(remaining);
        if (!Number.isInteger(written) || written < 0 || written > remaining.length) {
          throw new Error("invalid socket write count");
        }
        if (written === 0) break;
        this.pendingBytes -= written;
        this.offset += written;
        if (this.offset === head.length) {
          this.queue.shift();
          this.offset = 0;
        }
      }
    } catch {
      console.error(`[${this.label}] outbound write failed; closing connection`);
      this.fail();
    } finally {
      this.flushing = false;
      if (this.pendingBytes === 0) this.resolveEmpty();
    }
  }

  private resolveEmpty(): void {
    for (const resolve of this.emptyWaiters.splice(0)) resolve();
  }
}
