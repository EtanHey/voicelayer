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
    text
      // Strip all XML/HTML/SSML tags (including self-closing)
      .replace(/<[^>]*>/g, "")
      // Strip control characters (C0 except \t \n \r, plus C1)
      .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/g, " ")
      // Collapse multiple spaces into one (from tag removal)
      .replace(/ {2,}/g, " ")
      .trim()
  );
}
