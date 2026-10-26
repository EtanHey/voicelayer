import * as fs from "fs";
import { dirname, isAbsolute, join, normalize, parse } from "path";

export class UnsafeSpeechDirectory extends Error {}
const hasCode = (error: unknown, code: string) => typeof error === "object" && error !== null && "code" in error && error.code === code;
export function syncSpeechDirectory(path: string): void {
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}
function privateDirectory(path: string): void {
  const stat = fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 ||
      stat.uid !== process.getuid?.()) throw new UnsafeSpeechDirectory();
}

// Inspect each component before descent; never canonicalize an alias into acceptance.
// Existing shared ancestor permissions are not changed. The archive root/day must be private.
export function preparePrivateSpeechDirectory(root: string): void {
  if (!isAbsolute(root) || normalize(root) !== root || root === parse(root).root) {
    throw new UnsafeSpeechDirectory();
  }
  let current = parse(root).root;
  for (const component of root.slice(current.length).split("/")) {
    current = join(current, component);
    try {
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new UnsafeSpeechDirectory();
    } catch (error) {
      if (!hasCode(error, "ENOENT")) throw error;
      fs.mkdirSync(current, { mode: 0o700 });
      syncSpeechDirectory(current);
      syncSpeechDirectory(dirname(current));
    }
  }
  privateDirectory(root);
  syncSpeechDirectory(root);
  syncSpeechDirectory(dirname(root));
}
