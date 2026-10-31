import * as fs from "node:fs";
import { dirname, resolve } from "node:path";

type ExpectedPath = Readonly<{ path: string; dev: number; ino: number }>;
type SyncRequest = Readonly<{
  file: ExpectedPath;
  archiveRoot: string;
  rootParentRequired: boolean;
  // Exact immediate parent first, through archiveRoot (and its parent if required).
  directories: readonly ExpectedPath[];
}>;
type SyncIo = {
  openSync(path: string, flags: number): number;
  lstatSync(path: string): fs.Stats;
  fstatSync(fd: number): fs.Stats;
  realpathSync(path: string): string;
  fsyncSync(fd: number): void;
  closeSync(fd: number): void;
};
type SyncResult =
  | { kind: "synced"; closureStatus: "closed" }
  | { kind: "failed"; code: "sync-unavailable"; closureStatus: "closed" | "unconfirmed" };

/** Internal sync fact only. Caller owns bytes/hash verification, creation provenance,
 * lifecycle and its persistent writer. This acquires only temporary read handles.
 * Required links must already exist; no capture/completion/retention authority.
 */
export function syncRetainedConversationFile(request: SyncRequest, io: SyncIo = fs): SyncResult {
  const owned: { entry: ExpectedPath & { directory: boolean }; fd: number }[] = [];
  let failed = false;
  let closureStatus: "closed" | "unconfirmed" = "closed";
  try {
    const root = request.archiveRoot;
    const boundary = request.rootParentRequired ? dirname(root) : root;
    const entries = [
      { ...request.file, directory: false },
      ...request.directories.map((entry) => ({ ...entry, directory: true })),
    ];
    if (resolve(root) !== root || root === dirname(root) ||
        !request.file.path.startsWith(`${root}/`) ||
        request.directories.at(-1)?.path !== boundary ||
        !request.directories.some((entry) => entry.path === root)) throw new Error();
    let parent = dirname(request.file.path);
    for (const [index, entry] of request.directories.entries()) {
      if (entry.path !== parent || (parent === boundary && index !== request.directories.length - 1)) {
        throw new Error();
      }
      parent = dirname(parent);
    }
    const verify = (entry: ExpectedPath & { directory: boolean }, fd?: number): void => {
      if (resolve(entry.path) !== entry.path || io.realpathSync(entry.path) !== entry.path) throw new Error();
      const matches = (stat: fs.Stats): boolean => stat.dev === entry.dev && stat.ino === entry.ino &&
        (entry.directory ? stat.isDirectory() : stat.isFile());
      if (!matches(io.lstatSync(entry.path)) || (fd !== undefined && !matches(io.fstatSync(fd)))) {
        throw new Error();
      }
    };
    for (const entry of entries) {
      verify(entry);
      const fd = io.openSync(entry.path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW |
        fs.constants.O_NONBLOCK | (entry.directory ? fs.constants.O_DIRECTORY : 0));
      owned.push({ entry, fd });
      verify(entry, fd);
    }
    for (const { entry, fd } of owned) {
      verify(entry, fd);
      io.fsyncSync(fd);
      verify(entry, fd);
    }
    // Recheck earlier links too: a later sync may have raced their replacement.
    for (const { entry, fd } of owned) verify(entry, fd);
  } catch {
    failed = true;
  } finally {
    for (const { fd } of owned.toReversed()) {
      // Never probe/retry after close throws: even the same fd/inode may be another owner's.
      try { io.closeSync(fd); } catch { closureStatus = "unconfirmed"; }
    }
  }
  return failed || closureStatus === "unconfirmed"
    ? { kind: "failed", code: "sync-unavailable", closureStatus }
    : { kind: "synced", closureStatus: "closed" };
}
