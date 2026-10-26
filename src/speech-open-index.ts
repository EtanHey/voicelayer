import { mkdirSync, rmdirSync, openSync, closeSync, writeFileSync, fsyncSync, unlinkSync } from "fs";
import { isAbsolute, join, relative } from "path";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import { preparePrivateSpeechDirectory, syncSpeechDirectory } from "./speech-archive-directory";

function indexPath(suffix: string): string {
  const path = `${recordingsArchiveRoot()}.${suffix}`;
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT;
    const local = run ? relative(run, path) : "..";
    if (!run || !local || local === ".." || local.startsWith("../") || isAbsolute(local)) {
      throw new Error("speech index requires an isolated run path");
    }
  }
  return path;
}
export const speechOpenIndex = () => indexPath("speech-open");
export const speechPendingIndex = () => indexPath("speech-pending");

/** Directory names durably encode intent and owner before metadata publication. */
export function beginSpeechReceipt(id: string): void {
  const dir = speechPendingIndex();
  preparePrivateSpeechDirectory(dir);
  const pending = join(dir, id);
  mkdirSync(pending, { mode: 0o700 });
  const owner = join(pending, String(process.pid));
  mkdirSync(owner, { mode: 0o700 });
  syncSpeechDirectory(owner);
  syncSpeechDirectory(pending);
  syncSpeechDirectory(dir);
}
export function finishSpeechReceipt(id: string, pid: number): void {
  const dir = speechPendingIndex();
  preparePrivateSpeechDirectory(dir);
  try {
    rmdirSync(join(dir, id, String(pid)));
    syncSpeechDirectory(join(dir, id));
    rmdirSync(join(dir, id));
    syncSpeechDirectory(dir);
  }
  catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error; }
}
/** Only fully published receipt metadata enters the open-record index. */
export function indexOpenSpeech(id: string): void {
  const dir = speechOpenIndex();
  preparePrivateSpeechDirectory(dir);
  const fd = openSync(join(dir, id), "wx", 0o600);
  try { writeFileSync(fd, String(process.pid)); fsyncSync(fd); } finally { closeSync(fd); }
  syncIndex();
}
export function unindexSpeech(id: string): void {
  preparePrivateSpeechDirectory(speechOpenIndex());
  try { unlinkSync(join(speechOpenIndex(), id)); syncIndex(); }
  catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error; }
}
function syncIndex(): void {
  syncSpeechDirectory(speechOpenIndex());
}
