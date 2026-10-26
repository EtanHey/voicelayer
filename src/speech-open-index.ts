import { mkdirSync, openSync, closeSync, writeFileSync, fsyncSync, unlinkSync } from "fs";
import { join } from "path";
import { recordingsArchiveRoot } from "./recordings-archive-fs";

export const speechOpenIndex = () => join(recordingsArchiveRoot(), ".speech-open");
/** Durable intent precedes receipt publication, so missing metadata remains recoverable. */
export function indexOpenSpeech(id: string): void {
  const dir = speechOpenIndex();
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const fd = openSync(join(dir, id), "wx", 0o600);
  try { writeFileSync(fd, String(process.pid)); fsyncSync(fd); } finally { closeSync(fd); }
  syncIndex();
}
export function unindexSpeech(id: string): void {
  try { unlinkSync(join(speechOpenIndex(), id)); syncIndex(); }
  catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error; }
}
function syncIndex(): void {
  const fd = openSync(speechOpenIndex(), "r");
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
