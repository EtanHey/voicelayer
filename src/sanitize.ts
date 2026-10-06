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
 * Keep stray closing brackets and unmatched opening brackets verbatim.
 * Closed inner spans are still removed when their outer opening is unmatched.
 * This produces plain speech text; HTML sinks still need contextual escaping.
 */
export function stripMarkupForSpeech(text: string): string {
  const output: string[] = [];
  const openings: number[] = [];
  for (const char of text) {
    if (char === "<") openings.push(output.length);
    if (char === ">" && openings.length > 0) {
      // Removing a closed span is amortized linear: each output character is
      // appended once and can be discarded only once, even with nested tags.
      output.length = openings.pop()!;
    } else {
      output.push(char);
    }
  }
  return output.join("");
}
