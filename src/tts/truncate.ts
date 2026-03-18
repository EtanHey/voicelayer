/**
 * Word-boundary-aware text truncation for TTS engines.
 *
 * TTS engines have character limits (F5-TTS: 300, XTTS: 240) but naive
 * `.slice(0, N)` can cut mid-word, causing garbled speech output.
 * This utility truncates at the last word boundary before the limit.
 */

/**
 * Truncate text at a word boundary, never mid-word.
 *
 * @param text - Input text
 * @param maxLength - Maximum character length
 * @returns Truncated text ending at a word boundary, or original if under limit
 */
export function truncateAtWordBoundary(
  text: string,
  maxLength: number,
): string {
  if (text.length <= maxLength) return text;

  // Find the last space at or before the limit
  const truncated = text.slice(0, maxLength);
  const lastSpace = truncated.lastIndexOf(" ");

  // If no space found (single very long word), fall back to hard cut
  if (lastSpace === -1) return truncated;

  return truncated.slice(0, lastSpace);
}
