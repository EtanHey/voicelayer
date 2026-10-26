import { randomBytes } from "crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  openSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { dirname } from "path";
import { getRecordingsArchiveRoot } from "./paths";

export function recordingsArchiveRoot(): string {
  return getRecordingsArchiveRoot().replace(/\/+$/, "") || "/";
}

export function fsyncPath(path: string): void {
  let fd: number | undefined;
  try {
    fd = openSync(path, "r");
    fsyncSync(fd);
  } catch {
    // Directory fsync is best-effort across platforms and filesystems.
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {}
    }
  }
}

export function atomicWriteFile(path: string, data: string | Uint8Array): void {
  const tmpPath = `${path}.tmp-${process.pid}-${Date.now()}-${randomBytes(4).toString("hex")}`;
  let fd: number | undefined;
  let completed = false;
  try {
    try {
      fd = openSync(tmpPath, "w", 0o600);
      writeFileSync(fd, data);
      fsyncSync(fd);
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
    renameSync(tmpPath, path);
    fsyncPath(dirname(path));
    completed = true;
  } finally {
    if (!completed) {
      try {
        if (existsSync(tmpPath)) unlinkSync(tmpPath);
      } catch {}
    }
  }
}

export function archiveId(createdAt: Date): string {
  return `${createdAt.toISOString().replace(/[:.]/g, "-")}-${randomBytes(4).toString("hex")}`;
}
