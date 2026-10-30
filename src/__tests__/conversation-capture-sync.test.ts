import { expect, test } from "bun:test";
import * as fs from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { syncRetainedConversationFile as sync } from "../conversation-capture-sync";

type Request = Parameters<typeof sync>[0];
type Io = NonNullable<Parameters<typeof sync>[1]>;
const failed = { kind: "failed", code: "sync-unavailable", closureStatus: "closed" };
const synced = { kind: "synced", closureStatus: "closed" };
const bytes = Buffer.from([1, 2, 3, 4, 5]);
const hash = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
const identity = (path: string) => ({ path, dev: fs.statSync(path).dev, ino: fs.statSync(path).ino });

function fixture(run: (f: {
  request: Request; io: Io; file: string; base: string;
  opened: { path: string; fd: number; flags: number }[];
  attempts: number[]; syncedPaths: string[]; live: Set<number>;
  hooks: { close?: (fd: number) => void };
}) => void): void {
  const isolated = process.env.VOICELAYER_TMP_ROOT;
  if (!isolated) throw new Error("Canonical preload required");
  const base = fs.realpathSync(fs.mkdtempSync(join(isolated, "p4bs-")));
  const root = join(base, "archive");
  const take = join(root, "day", "take");
  fs.mkdirSync(take, { recursive: true });
  const file = join(take, "take.raw");
  fs.writeFileSync(file, bytes);
  const writer = fs.openSync(file, "r+");
  const writerIdentity = fs.fstatSync(writer);
  const verifyBytes = () => {
    expect(fs.fstatSync(writer).size).toBe(bytes.length);
    const observed = Buffer.alloc(bytes.length);
    expect(fs.readSync(writer, observed, 0, observed.length, 0)).toBe(bytes.length);
    expect(observed).toEqual(bytes);
    expect(hash(observed)).toBe(hash(bytes));
  };
  const paths = [file, take, dirname(take), root, base];
  const opened: { path: string; fd: number; flags: number }[] = [];
  const attempts: number[] = [], syncedPaths: string[] = [];
  const live = new Set<number>();
  const hooks: { close?: (fd: number) => void } = {};
  const io: Io = {
    lstatSync: fs.lstatSync, fstatSync: fs.fstatSync, realpathSync: fs.realpathSync,
    openSync(path, flags) {
      const fd = fs.openSync(path, flags);
      opened.push({ path, fd, flags });
      live.add(fd);
      return fd;
    },
    fsyncSync(fd) {
      verifyBytes();
      fs.fsyncSync(fd);
      verifyBytes();
      const entry = opened.find((value) => value.fd === fd);
      if (!entry) throw new Error("Unexpected unowned sync descriptor");
      syncedPaths.push(entry.path);
    },
    closeSync(fd) {
      attempts.push(fd);
      if (hooks.close) hooks.close(fd);
      else { fs.closeSync(fd); live.delete(fd); }
    },
  };
  try {
    run({ request: { file: identity(file), archiveRoot: root, rootParentRequired: true,
      directories: paths.slice(1).map(identity) }, io, file, base, opened, attempts, syncedPaths, live, hooks });
  } finally {
    try {
      expect(attempts).toHaveLength(opened.length);
      for (const { fd } of opened) expect(attempts.filter((value) => value === fd)).toHaveLength(1);
      verifyBytes();
      expect(fs.fstatSync(writer).ino).toBe(writerIdentity.ino);
    } finally {
      // Only test authority reclaims deliberately ambiguous original/replacement fds.
      for (const fd of live) fs.closeSync(fd);
      fs.closeSync(writer);
      fs.rmSync(base, { recursive: true });
      expect(fs.existsSync(base)).toBe(false);
    }
  }
}

test("strict regression: actual permission/open failure refuses sync", () => fixture((f) => {
  fs.chmodSync(f.file, 0);
  try {
    expect(() => fs.readFileSync(f.file)).toThrow();
    expect(sync(f.request, f.io)).toEqual(failed);
    expect(f.syncedPaths).toEqual([]);
  } finally { fs.chmodSync(f.file, 0o600); }
}));

for (const parentRequired of [false, true]) {
  test(`actual fsync chain, fresh/existing hierarchy, parent=${parentRequired}`, () => fixture((f) => {
    const request = { ...f.request, rootParentRequired: parentRequired,
      directories: parentRequired ? f.request.directories : f.request.directories.slice(0, -1) };
    const expected = [f.file, ...request.directories.map((entry) => entry.path)];
    expect(sync(request, f.io)).toEqual(synced);
    expect(f.syncedPaths).toEqual(expected);
    for (const [index, entry] of f.opened.entries()) {
      expect(entry.flags & fs.constants.O_NOFOLLOW).toBe(fs.constants.O_NOFOLLOW);
      if (index > 0) expect(entry.flags & fs.constants.O_DIRECTORY).toBe(fs.constants.O_DIRECTORY);
    }
    for (const { fd } of f.opened) expect(f.attempts.filter((value) => value === fd)).toHaveLength(1);
    expect(f.live.size).toBe(0);
    f.opened.length = f.attempts.length = f.syncedPaths.length = 0;
    expect(sync(request, f.io)).toEqual(synced);
    expect(f.syncedPaths).toEqual(expected);
    expect(fs.readFileSync(f.file)).toEqual(bytes);
  }));
}

test("a previous sync does not guarantee a later call or trigger automatic retry", () => fixture((f) => {
  expect(sync(f.request, f.io)).toEqual(synced);
  expect(f.live.size).toBe(0);
  for (const { fd } of f.opened) expect(f.attempts.filter((value) => value === fd)).toHaveLength(1);
  f.opened.length = f.attempts.length = f.syncedPaths.length = 0;
  let calls = 0;
  f.io.fsyncSync = () => { calls++; throw new Error("persistent failure"); };
  expect(sync(f.request, f.io)).toEqual(failed);
  expect(calls).toBe(1);
}));

const invalid = [
  (r: Request) => ({ ...r, archiveRoot: "/" }),
  (r: Request) => ({ ...r, archiveRoot: `${r.archiveRoot}-foreign` }),
  (r: Request) => ({ ...r, file: { ...r.file, path: `${r.archiveRoot}/../outside` } }),
  (r: Request) => ({ ...r, file: { ...r.file, path: "relative.raw" } }),
  (r: Request) => ({ ...r, directories: r.directories.slice(0, -1) }),
  (r: Request) => ({ ...r, directories: r.directories.slice(1) }),
  (r: Request) => ({ ...r, directories: [...r.directories, identity(dirname(r.archiveRoot))] }),
  (r: Request) => ({ ...r, file: { ...r.file, ino: r.file.ino + 1 } }),
  (r: Request) => ({ ...r, file: { ...r.file, dev: r.file.dev + 1 } }),
  (r: Request) => ({ ...r, file: identity(dirname(r.file.path)) }),
];
for (const [index, change] of invalid.entries()) {
  test(`boundary/escape/identity/type refusal ${index}`, () => fixture((f) => {
    expect(sync(change(f.request), f.io)).toEqual(failed);
    expect(f.syncedPaths).toEqual([]);
    expect(f.live.size).toBe(0);
  }));
}
for (const target of [0, 1, 2, 3, 4]) {
  test(`wrong expected directory/file identity ${target}`, () => fixture((f) => {
    const directories = f.request.directories.map((entry, index) => index === target - 1
      ? { ...entry, ino: entry.ino + 1 } : entry);
    const file = target === 0 ? { ...f.request.file, ino: f.request.file.ino + 1 } : f.request.file;
    expect(sync({ ...f.request, file, directories }, f.io)).toEqual(failed);
    expect(f.syncedPaths).toEqual([]);
  }));
  test(`actual sync error at file/directory ${target}`, () => fixture((f) => {
    const actual = f.io.fsyncSync;
    f.io.fsyncSync = (fd) => {
      if (fd === f.opened[target]?.fd) throw new Error("injected sync failure");
      actual(fd);
    };
    expect(sync(f.request, f.io)).toEqual(failed);
    expect(f.syncedPaths).toEqual([f.file, ...f.request.directories.map((d) => d.path)].slice(0, target));
    expect(f.live.size).toBe(0);
  }));
  for (const op of ["open", "path-read", "lstat", "fstat"]) {
    test(`${op} failure at acquisition ${target}`, () => fixture((f) => {
      const path = [f.file, ...f.request.directories.map((d) => d.path)][target];
      const reject = () => { throw new Error(`injected ${op}`); };
      if (op === "open") {
        const actual = f.io.openSync;
        f.io.openSync = (p, flags) => p === path ? reject() : actual(p, flags);
      } else if (op === "path-read") {
        f.io.realpathSync = (p) => p === path ? reject() : fs.realpathSync(p);
      } else if (op === "lstat") {
        f.io.lstatSync = (p) => p === path ? reject() : fs.lstatSync(p);
      } else {
        f.io.fstatSync = (fd) => fd === f.opened[target]?.fd ? reject() : fs.fstatSync(fd);
      }
      expect(sync(f.request, f.io)).toEqual(failed);
      expect(f.syncedPaths).toEqual([]);
      expect(f.live.size).toBe(0);
    }));
  }
}

for (const timing of ["before-open", "after-open", "after-sync", "final-check"]) {
  test(`actual file identity substitution ${timing}`, () => fixture((f) => {
    const replace = () => { fs.renameSync(f.file, `${f.file}.old`); fs.writeFileSync(f.file, bytes); };
    if (timing === "before-open" || timing === "after-open") {
      const actual = f.io.openSync;
      f.io.openSync = (path, flags) => {
        if (path === f.file && timing === "before-open") replace();
        const fd = actual(path, flags);
        if (path === f.file && timing === "after-open") replace();
        return fd;
      };
    } else {
      const actual = f.io.fsyncSync;
      f.io.fsyncSync = (fd) => {
        actual(fd);
        if (fd === f.opened[timing === "after-sync" ? 0 : 4]?.fd) replace();
      };
    }
    expect(sync(f.request, f.io)).toEqual(failed);
    expect(f.live.size).toBe(0);
    expect(fs.readFileSync(f.file)).toEqual(bytes);
  }));
}
for (const directory of [false, true]) {
  test(`actual symlink substitution directory=${directory}`, () => fixture((f) => {
    const path = directory ? dirname(f.file) : f.file;
    fs.renameSync(path, `${path}.old`);
    fs.symlinkSync(`${path}.old`, path);
    expect(sync(f.request, f.io)).toEqual(failed);
    expect(f.syncedPaths).toEqual([]);
    expect(f.live.size).toBe(0);
  }));
}

test("opened fd must identify the expected file even while its path still matches", () => fixture((f) => {
  const foreign = join(f.base, "foreign.raw");
  fs.writeFileSync(foreign, bytes);
  const actual = f.io.openSync;
  f.io.openSync = (path, flags) => actual(path === f.file ? foreign : path, flags);
  expect(sync(f.request, f.io)).toEqual(failed);
  expect(f.syncedPaths).toEqual([]);
  expect(f.live.size).toBe(0);
}));
test("final verification refuses a replaced directory link after all syncs", () => fixture((f) => {
  const actual = f.io.fsyncSync;
  f.io.fsyncSync = (fd) => {
    actual(fd);
    if (fd === f.opened[4]?.fd) {
      const take = dirname(f.file);
      fs.renameSync(take, `${take}.old`);
      fs.mkdirSync(take);
      fs.writeFileSync(f.file, bytes);
    }
  };
  expect(sync(f.request, f.io)).toEqual(failed);
  expect(f.syncedPaths).toHaveLength(5);
  expect(f.live.size).toBe(0);
}));

for (const target of [0, 1, 2, 3, 4]) {
  for (const mode of ["persistent-before", "after", "same-inode", "different-inode"]) {
    test(`close ${mode} target=${target}; no retry/replacement closure`, () => fixture((f) => {
      let replacement: number | undefined;
      let original: fs.Stats | undefined;
      const foreign = join(f.base, "foreign.raw");
      fs.writeFileSync(foreign, bytes);
      f.hooks.close = (fd) => {
        if (fd !== f.opened[target]?.fd) { fs.closeSync(fd); f.live.delete(fd); return; }
        if (mode === "persistent-before") throw new Error("original remains open");
        original = fs.fstatSync(fd);
        fs.closeSync(fd);
        f.live.delete(fd);
        if (mode !== "after") {
          replacement = fs.openSync(mode === "same-inode" ? f.opened[target].path : foreign, "r");
          f.live.add(replacement);
        }
        throw new Error("ambiguous close");
      };
      expect(sync(f.request, f.io)).toEqual({ ...failed, closureStatus: "unconfirmed" });
      expect(f.attempts).toHaveLength(5);
      expect(f.live.size).toBe(mode === "after" ? 0 : 1);
      if (mode === "same-inode" || mode === "different-inode") expect(replacement).toBe(f.opened[target].fd);
      if (replacement !== undefined) {
        const stat = fs.fstatSync(replacement);
        expect(stat.ino === original?.ino).toBe(mode === "same-inode");
        if (mode === "same-inode") {
          expect([stat.dev, stat.size, stat.mtimeMs]).toEqual([original?.dev, original?.size, original?.mtimeMs]);
        }
        expect(stat.isFile() || stat.isDirectory()).toBe(true);
        if (stat.isFile()) {
          const observed = Buffer.alloc(bytes.length);
          expect(fs.readSync(replacement, observed, 0, observed.length, 0)).toBe(bytes.length);
          expect(observed).toEqual(bytes);
        }
      }
      console.log(JSON.stringify({ target, mode, attempts: f.attempts, unresolvedOrReplacement: [...f.live] }));
    }));
  }
}

test("verification failure and every close failing preserve unconfirmed status", () => fixture((f) => {
  f.io.fsyncSync = () => { throw new Error("sync failed"); };
  f.hooks.close = () => { throw new Error("persistent before-close failure"); };
  expect(sync(f.request, f.io)).toEqual({ ...failed, closureStatus: "unconfirmed" });
  expect(f.attempts).toHaveLength(5);
  expect(f.live.size).toBe(5);
}));
