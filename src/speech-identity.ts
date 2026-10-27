import { createHash } from "node:crypto";

/** Match Swift Unicode.Scalar.Properties.isWhitespace, including NEL (which JS \s omits). */
export function normalizedSpeechHash(text: string): string {
  const normalized = text.split(/[\p{White_Space}]+/u).filter(Boolean).join(" ");
  return createHash("sha256").update(normalized, "utf8").digest("hex");
}

export function selectionIdentity(text: string): string {
  let fence: { marker: string; length: number } | undefined;
  const lines = text.split(/[\n\r\v\f\u0085\u2028\u2029]/u).map(line => {
    const delimiter = /^ {0,3}(`{3,}|~{3,})(.*)$/u.exec(line);
    if (fence) {
      if (delimiter && delimiter[1]?.[0] === fence.marker && delimiter[1].length >= fence.length && !delimiter[2]?.trim()) fence = undefined;
      return line;
    }
    if (delimiter?.[1]) {
      fence = { marker: delimiter[1].charAt(0), length: delimiter[1].length };
      return line;
    }
    if (/^(?: {4}| {0,3}\t)/u.test(line)) return line;
    return line.replace(/^[\t \p{Zs}]*(?:(?:[-+*]|[0-9]+[.)])[\t \p{Zs}]+)?(?:\[[ xX]\][\t \p{Zs}]+)?/u, "");
  });
  const collapse = (value: string) => value.split(/[\p{White_Space}]+/u).filter(Boolean).join(" ").normalize("NFC");
  return collapse(lines.join("\n")) || collapse(text);
}
