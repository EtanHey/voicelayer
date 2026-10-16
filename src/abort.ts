// Bun 1.3.9 can collect the reason when abort precedes the first .signal read.
// Use the reason getter (which can rebuild it), never the native throw slot.
export function abortErrorFor(signal: AbortSignal): Error | DOMException {
  const reason: unknown = signal.reason;
  return reason instanceof Error || reason instanceof DOMException
    ? reason
    : new DOMException("Aborted", "AbortError");
}

export function throwIfAbortedSafe(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortErrorFor(signal);
}
