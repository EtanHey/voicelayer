import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative } from "node:path";
import { createConversationSpool } from "../conversation-capture-spool";

const input = { generation: 7, format: { sampleRate: 24000, channels: 1, encoding: "s16le", provenance: "requested" } } satisfies Parameters<typeof createConversationSpool>[0];
const A = Buffer.from([1, 2, 3, 4, 5]), B = Buffer.from([11, 12, 13]);
const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const live = new Set<number>();
const ambiguous = new Set<number>();
const owners: Extract<ReturnType<typeof createConversationSpool>, { kind: "opened" }>["spool"][] = [];
const opened: number[] = [];
let root: string, archive: string;
const release = (fd: number) => { fs.closeSync(fd); live.delete(fd); };
const acquire: typeof fs.openSync = (...args) => {
  const fd = fs.openSync(...args);
  live.add(fd);
  opened.push(fd);
  return fd;
};
function make(hooks: Parameters<typeof createConversationSpool>[1] = {}) {
  const result = createConversationSpool(input, { open: acquire, close: release, ...hooks });
  if (result.kind !== "opened") throw new Error("synthetic setup failed");
  owners.push(result.spool);
  return result.spool;
}
beforeEach(() => {
  const run = process.env.VOICELAYER_TEST_RUN_ROOT;
  archive = process.env.QA_VOICE_RECORDINGS_DIR ?? "";
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !archive ||
      relative(run, archive).startsWith("..") || relative(run, archive) === "") throw new Error("preload required");
  root = fs.mkdtempSync(join(archive, "p4b1-"));
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  opened.length = 0;
});
afterEach(() => {
  for (const owner of owners.splice(0)) owner.close();
  try { expect([...live]).toEqual([...ambiguous]); } finally {
    // Only fixtures reclaim deliberately ambiguous synthetic descriptors; production must never retry.
    for (const fd of live) release(fd);
    expect(live.size).toBe(0);
    ambiguous.clear();
    process.env.QA_VOICE_RECORDINGS_DIR = archive;
    fs.rmSync(root, { recursive: true });
  }
});

test("exclusive takes preserve A across B, private modes, native odd tail and provenance", () => {
  const a = make();
  a.appendNative(A);
  const first = a.close();
  const b = make();
  b.appendNative(B);
  b.close();
  expect(b.path).not.toBe(a.path);
  expect(fs.readFileSync(b.path)).toEqual(B);
  expect(fs.readFileSync(a.path)).toEqual(A);
  expect(first.raw).toEqual({ kind: "verified", path: a.path, verifiedBytes: 5, sha256: hash(A) });
  expect(first).toMatchObject({ generation: 7, format: input.format, observedBytes: 5, writtenBytes: 5, closureStatus: "closed", fault: false });
  expect(fs.statSync(dirname(a.path)).mode & 0o777).toBe(0o700);
  expect(fs.statSync(a.path).mode & 0o777).toBe(0o600);
  const id = dirname(a.path).split("/").at(-1)!;
  expect(createConversationSpool(input, { id: () => id }).kind).toBe("unavailable");
  expect(hash(fs.readFileSync(a.path))).toBe(hash(A));
});

test("copies caller bytes before ordered short writes; empty chunks do nothing", () => {
  const supplied = Buffer.from(A);
  let calls = 0;
  const owner = make({ write: (fd, bytes, offset, length, position) => {
    supplied.fill(99);
    calls++;
    return fs.writeSync(fd, bytes, offset, Math.min(2, length), position);
  } });
  owner.appendNative(supplied);
  owner.appendNative(new Uint8Array());
  owner.appendNative(B);
  expect(calls).toBe(5);
  expect(owner.close()).toMatchObject({ observedBytes: 8, writtenBytes: 8, raw: { verifiedBytes: 8, sha256: hash(Buffer.concat([A, B])) } });
  expect(fs.readFileSync(owner.path)).toEqual(Buffer.concat([A, B]));
});

test.each(["throw", "zero", "negative", "oversized"])("partial B then %s latches; C cannot extend the prefix", fault => {
  let calls = 0;
  const owner = make({ write: (fd, bytes, offset, length, position) => {
    calls++;
    if (calls === 3) {
      if (fault === "throw") throw new Error("synthetic write failure");
      return fault === "zero" ? 0 : fault === "negative" ? -1 : length + 1;
    }
    return fs.writeSync(fd, bytes, offset, calls === 2 ? 1 : length, position);
  } });
  owner.appendNative(A);
  owner.appendNative(B);
  owner.appendNative(Buffer.from([77, 78]));
  const prefix = Buffer.concat([A, B.subarray(0, 1)]);
  expect(calls).toBe(3);
  expect(fs.readFileSync(owner.path)).toEqual(prefix);
  expect(owner.close()).toMatchObject({ observedBytes: 10, writtenBytes: 6, fault: true, closureStatus: "closed", raw: { verifiedBytes: 6, sha256: hash(prefix) } });
});

test.each(["read", "replace", "truncate", "overwrite"])("independent verification refuses %s faults without deleting files", fault => {
  const owner = make({ read: fd => {
    if (fault === "read") throw new Error("synthetic read failure");
    return fs.readFileSync(fd);
  } });
  owner.appendNative(A);
  if (fault === "replace") {
    fs.renameSync(owner.path, owner.path + ".original");
    fs.writeFileSync(owner.path, A, { mode: 0o600 });
  }
  if (fault === "truncate") fs.truncateSync(owner.path, 2);
  if (fault === "overwrite") fs.writeFileSync(owner.path, Buffer.alloc(5, 88));
  expect(owner.close()).toMatchObject({ observedBytes: 5, writtenBytes: 5, raw: { kind: "unavailable", verifiedBytes: null }, closureStatus: "closed" });
  expect(fs.existsSync(owner.path)).toBe(true);
});

test("positive empty differs from observed bytes with no retained prefix; terminal calls are idempotent", () => {
  const empty = make();
  expect(empty.close().raw).toEqual({ kind: "verified", path: empty.path, verifiedBytes: 0, sha256: hash(Buffer.alloc(0)) });
  const owner = make({ write: () => { throw new Error("no storage"); }, read: () => { throw new Error("unreadable"); } });
  owner.appendNative(A);
  const result = owner.close();
  expect(result).toMatchObject({ observedBytes: 5, writtenBytes: 0, fault: true, raw: { kind: "unavailable", verifiedBytes: null } });
  expect(owner.close()).toBe(result);
  expect(() => owner.appendNative(B)).toThrow();
});

test("refuses a foreign staging symlink without adopting or modifying it", () => {
  const foreign = join(root, "foreign");
  fs.mkdirSync(foreign, { mode: 0o700 });
  fs.writeFileSync(join(foreign, "keep"), A);
  fs.symlinkSync(foreign, join(root, ".conversation-captures"));
  expect(createConversationSpool(input).kind).toBe("unavailable");
  expect(fs.readdirSync(foreign)).toEqual(["keep"]);
  expect(fs.readFileSync(join(foreign, "keep"))).toEqual(A);
});

test("observed nonempty bytes with an independently readable empty file are unavailable", () => {
  const owner = make({ write: () => { throw new Error("failed before first byte"); } });
  owner.appendNative(A);
  expect(fs.readFileSync(owner.path)).toEqual(Buffer.alloc(0));
  expect(owner.close()).toMatchObject({ observedBytes: 5, writtenBytes: 0, raw: { kind: "unavailable", verifiedBytes: null }, closureStatus: "closed" });
});

test.each(["before-open", "foreign-file", "after-open"])("partial setup %s closes only acquired descriptors and retains foreign bytes", fault => {
  const result = createConversationSpool(input, { open: (path, flags, mode) => {
    if (fault === "before-open") throw new Error("open failed");
    if (fault === "foreign-file") fs.writeFileSync(path, B, { flag: "wx", mode: 0o600 });
    const fd = acquire(path, flags, mode);
    if (fault === "after-open") fs.chmodSync(path, 0o644);
    return fd;
  }, close: release });
  expect(result).toMatchObject({ kind: "unavailable", closureStatus: "closed" });
  expect(live.size).toBe(0);
  const takes = join(root, ".conversation-captures");
  const file = join(takes, fs.readdirSync(takes)[0]!, "native.pcm");
  if (fault === "foreign-file") expect(fs.readFileSync(file)).toEqual(B);
  if (fault === "after-open") expect(fs.readFileSync(file)).toEqual(Buffer.alloc(0));
});

test("setup verification failure with persistent close-before remains explicitly unconfirmed", () => {
  const result = createConversationSpool(input, { open: (path, flags, mode) => {
    const fd = acquire(path, flags, mode);
    fs.chmodSync(path, 0o644);
    return fd;
  }, close: fd => { ambiguous.add(fd); throw new Error("persistent setup close fault"); } });
  expect(result).toMatchObject({ kind: "unavailable", closureStatus: "unconfirmed" });
  expect(live.size).toBe(1);
});

for (const target of ["writer", "reader"]) {
  test.each(["before", "after", "different-file", "same-inode"])(`${target} close %s is single-attempt and unconfirmed`, fault => {
    const attempts: number[] = [];
    let replacement: number | undefined;
    let replacedFd = -1;
    let identity: fs.Stats | undefined;
    const owner = make({ close: fd => {
      attempts.push(fd);
      const selected = target === "writer" ? opened[0] : opened[1];
      if (fd !== selected) return release(fd);
      if (fault !== "before") release(fd);
      if (fault === "different-file" || fault === "same-inode") {
        const path = fault === "same-inode" ? owner.path : join(root, "replacement");
        if (fault === "different-file") fs.writeFileSync(path, B);
        identity = fs.statSync(path);
        replacedFd = fd;
        replacement = acquire(path, "r");
        ambiguous.add(replacement);
      }
      if (fault === "before") ambiguous.add(fd);
      throw new Error("ambiguous synthetic close");
    } });
    owner.appendNative(A);
    const result = owner.close();
    expect(result).toMatchObject({ closureStatus: "unconfirmed", raw: { kind: "verified", verifiedBytes: 5, sha256: hash(A) } });
    expect(result.errors.length).toBeGreaterThan(0);
    expect(String(result.errors[0]?.cause)).toBe("Error: ambiguous synthetic close");
    expect(owner.close()).toBe(result);
    expect(attempts.length).toBe(2);
    expect(new Set(attempts).size).toBe(2);
    if (fault === "before") expect(live.has(target === "writer" ? opened[0]! : opened[1]!)).toBe(true);
    if (fault === "before") expect(fs.fstatSync(target === "writer" ? opened[0]! : opened[1]!).isFile()).toBe(true);
    if (replacement !== undefined) {
      if (!identity) throw new Error("replacement identity was not observed");
      expect(replacement).toBe(replacedFd);
      expect(fs.fstatSync(replacement)).toMatchObject({ ino: identity.ino, dev: identity.dev, mode: identity.mode, size: identity.size, ctimeMs: identity.ctimeMs, mtimeMs: identity.mtimeMs });
      expect(fs.readFileSync(replacement)).toEqual(fault === "same-inode" ? A : B);
    }
    expect(fs.readFileSync(owner.path)).toEqual(A);
  });
}
