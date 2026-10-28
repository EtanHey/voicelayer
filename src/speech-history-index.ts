import { closeSync, constants, fstatSync, fsyncSync, openSync } from "fs";
import { join } from "path";
import { speechHistoryIndex } from "./speech-open-index";
import { preparePrivateSpeechDirectory, syncSpeechDirectory } from "./speech-archive-directory";

export function indexSpeechHistory(id: string): void {
  try {
    if (!/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(id)) throw new Error("Invalid speech history identity");
    const directory = speechHistoryIndex();
    preparePrivateSpeechDirectory(directory);
    const fd = openSync(join(directory, id), constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) throw new Error("Unsafe speech history marker");
      fsyncSync(fd);
    } finally { closeSync(fd); }
    syncSpeechDirectory(directory);
  } catch {
    console.error("[speech] history membership write failed");
  }
}
