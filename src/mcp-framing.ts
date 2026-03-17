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

/**
 * Parse zero or more complete MCP frames from a buffer.
 * Returns parsed messages and any remaining unparsed bytes.
 */
export function parseMcpFrames(data: string): {
  messages: Record<string, unknown>[];
  remainder: string;
} {
  const messages: Record<string, unknown>[] = [];
  let buffer = data;

  while (buffer.length > 0) {
    // Find the header delimiter
    const delimIdx = buffer.indexOf(HEADER_DELIM);
    if (delimIdx === -1) {
      // Incomplete header — return as remainder
      break;
    }

    // Extract Content-Length value from header
    const header = buffer.slice(0, delimIdx);
    if (!header.startsWith(HEADER_PREFIX)) {
      break;
    }

    const contentLength = parseInt(header.slice(HEADER_PREFIX.length), 10);
    if (isNaN(contentLength) || contentLength < 0) {
      break;
    }

    // Check if we have enough bytes for the body
    const bodyStart = delimIdx + HEADER_DELIM.length;
    const bodyBytes = Buffer.byteLength(buffer.slice(bodyStart), "utf-8");

    if (bodyBytes < contentLength) {
      // Incomplete body — return everything as remainder
      break;
    }

    // Extract exactly contentLength bytes of body
    // We need to handle the byte-length vs char-length difference
    const bodyBuf = Buffer.from(buffer.slice(bodyStart), "utf-8");
    const jsonStr = bodyBuf.subarray(0, contentLength).toString("utf-8");
    const remainingBytes = bodyBuf.subarray(contentLength).toString("utf-8");

    try {
      const parsed = JSON.parse(jsonStr);
      messages.push(parsed);
    } catch {
      // Invalid JSON — skip this frame
      break;
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
 */
export function detectProtocol(data: string): "mcp" | "ndjson" | "unknown" {
  if (data.length === 0) return "unknown";

  // Trim leading whitespace for NDJSON detection
  const trimmed = data.trimStart();

  if (
    data.startsWith("Content-Length:") ||
    data.startsWith("Content-Length ")
  ) {
    return "mcp";
  }

  if (trimmed.length === 0) return "unknown";

  if (trimmed[0] === "{" || trimmed[0] === "[") {
    return "ndjson";
  }

  // Need more data if we only have a few chars that could be start of Content-Length
  if (data.length < 2 && "C".startsWith(data)) {
    return "unknown";
  }

  return "unknown";
}
