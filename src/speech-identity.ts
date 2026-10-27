import { createHash } from "node:crypto";

/** Match Swift Unicode.Scalar.Properties.isWhitespace, including NEL (which JS \s omits). */
export function normalizedSpeechHash(text: string): string {
  const normalized = text.split(/[\p{White_Space}]+/u).filter(Boolean).join(" ");
  return createHash("sha256").update(normalized, "utf8").digest("hex");
}

export function selectionIdentity(text: string): string {
  return text.replace(/^[\t \p{Zs}]*(?:(?:[-+*]|[0-9]+[.)])[\t \p{Zs}]+)?(?:\[[ xX]\][\t \p{Zs}]+)?/gmu, "")
    .split(/[\p{White_Space}]+/u).filter(Boolean).join(" ");
}
