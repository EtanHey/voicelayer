/**
 * MCP Content-Length framing parser and serializer.
 *
 * MCP uses LSP-style framing: `Content-Length: N\r\n\r\n{json}`
 * where N is the byte length of the JSON body.
 *
 * Also provides protocol detection: first bytes determine MCP vs NDJSON.
 */

const HEADER_DELIM = "\r\n\r\n";
const HEADER_PREFIX = "Content-Length: ";

/** Maximum allowed frame size (10 MB) — prevents unbounded buffering. */
const MAX_FRAME_SIZE = 10 * 1024 * 1024;

export interface ParseResult {
  messages: Record<string, unknown>[];
  remainder: string;
  /** Non-null if a malformed frame was encountered (bad header, invalid JSON, oversized). */
  error?: string;
}

/**
 * Parse zero or more complete MCP frames from a buffer.
 * Returns parsed messages, any remaining unparsed bytes, and an error if
 * a malformed frame was encountered. On error, the offending frame is
 * consumed (not left in remainder) to prevent infinite retry loops.
 */
export function parseMcpFrames(data: string): ParseResult {
  const messages: Record<string, unknown>[] = [];
  let buffer = data;

  while (buffer.length > 0) {
    // Find the header delimiter
    const delimIdx = buffer.indexOf(HEADER_DELIM);
    if (delimIdx === -1) {
      // Incomplete header — return as remainder (need more data)
      break;
    }

    // Extract Content-Length value from header
    const header = buffer.slice(0, delimIdx);
    if (!header.startsWith(HEADER_PREFIX)) {
      // Malformed header — consume it to prevent infinite loop
      const consumeTo = delimIdx + HEADER_DELIM.length;
      buffer = buffer.slice(consumeTo);
      return {
        messages,
        remainder: buffer,
        error: `Malformed header: ${header}`,
      };
    }

    const contentLength = parseInt(header.slice(HEADER_PREFIX.length), 10);
    if (isNaN(contentLength) || contentLength < 0) {
      // Invalid Content-Length — consume the header
      const consumeTo = delimIdx + HEADER_DELIM.length;
      buffer = buffer.slice(consumeTo);
      return {
        messages,
        remainder: buffer,
        error: `Invalid Content-Length: ${header}`,
      };
    }

    if (contentLength > MAX_FRAME_SIZE) {
      // Oversized frame — consume header, reject
      const consumeTo = delimIdx + HEADER_DELIM.length;
      buffer = buffer.slice(consumeTo);
      return {
        messages,
        remainder: buffer,
        error: `Frame too large: ${contentLength} bytes (max ${MAX_FRAME_SIZE})`,
      };
    }

    // Check if we have enough bytes for the body
    const bodyStart = delimIdx + HEADER_DELIM.length;
    const bodyBytes = Buffer.byteLength(buffer.slice(bodyStart), "utf-8");

    if (bodyBytes < contentLength) {
      // Incomplete body — return everything as remainder (need more data)
      break;
    }

    // Extract exactly contentLength bytes of body
    // Handle byte-length vs char-length difference for unicode
    const bodyBuf = Buffer.from(buffer.slice(bodyStart), "utf-8");
    const jsonStr = bodyBuf.subarray(0, contentLength).toString("utf-8");
    const remainingBytes = bodyBuf.subarray(contentLength).toString("utf-8");

    try {
      const parsed = JSON.parse(jsonStr);
      messages.push(parsed);
    } catch {
      // Invalid JSON — consume the frame (header + body) to prevent infinite loop
      buffer = remainingBytes;
      return {
        messages,
        remainder: buffer,
        error: `Invalid JSON in frame: ${jsonStr.slice(0, 100)}`,
      };
    }

    buffer = remainingBytes;
  }

  return { messages, remainder: buffer };
}

/**
 * Serialize a JSON object into an MCP Content-Length frame.
 */
export function serializeMcpFrame(body: Record<string, unknown>): string {
  const json = JSON.stringify(body);
  const byteLen = Buffer.byteLength(json, "utf-8");
  return `${HEADER_PREFIX}${byteLen}${HEADER_DELIM}${json}`;
}

/**
 * Detect protocol from first bytes of data.
 * Returns "mcp" for Content-Length framing, "ndjson" for JSON, "unknown" otherwise.
 *
 * Uses the exact HEADER_PREFIX ("Content-Length: ") to stay aligned with parseMcpFrames.
 */
export function detectProtocol(data: string): "mcp" | "ndjson" | "unknown" {
  if (data.length === 0) return "unknown";

  // Trim leading whitespace for NDJSON detection
  const trimmed = data.trimStart();

  // Must match exact prefix that parseMcpFrames expects
  if (data.startsWith(HEADER_PREFIX)) {
    return "mcp";
  }

  if (trimmed.length === 0) return "unknown";

  if (trimmed[0] === "{" || trimmed[0] === "[") {
    return "ndjson";
  }

  // Need more data if we only have a few chars that could be start of Content-Length
  if (data.length < HEADER_PREFIX.length && HEADER_PREFIX.startsWith(data)) {
    return "unknown";
  }

  return "unknown";
}
