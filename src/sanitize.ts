/**
 * Text sanitization for TTS input.
 *
 * Defense-in-depth against SSML injection — strips XML/HTML tags and
 * control characters before text reaches any TTS engine (edge-tts, Qwen3).
 * Even though edge-tts doesn't interpret SSML by default, this prevents
 * future regressions if backends change.
 */

/**
 * Strip HTML/SSML tags and control characters from TTS text.
 * Preserves normal punctuation, Unicode, and whitespace.
 */
export function sanitizeTtsText(text: string): string {
  return (
    stripMarkupForSpeech(text)
      // Strip control characters (C0 except \t \n \r, plus C1)
      .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/g, " ")
      // Collapse multiple spaces into one (from tag removal)
      .replace(/ {2,}/g, " ")
      .trim()
  );
}

/** Remove balanced tag spans, including nested malformed tags, in one pass.
 * An unmatched bracket is removed without discarding the following words.
 * This produces plain speech text; HTML sinks still need contextual escaping.
 */
export function stripMarkupForSpeech(text: string): string {
  const parts: string[] = [];
  let depth = 0;
  let cursor = 0;
  let tagStart = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "<") {
      if (depth === 0) {
        parts.push(text.slice(cursor, i));
        tagStart = i;
      }
      depth++;
    } else if (text[i] === ">") {
      if (depth > 0) {
        depth--;
        if (depth === 0) cursor = i + 1;
      } else {
        parts.push(text.slice(cursor, i));
        cursor = i + 1;
      }
    }
  }
  parts.push(depth > 0 ? text.slice(tagStart).replace(/[<>]/g, "") : text.slice(cursor));
  return parts.join("");
}
