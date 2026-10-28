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

test("live A/inspect/B/inspect/close independently rereads each prefix and keeps snapshots stable", () => {
  const attempts: number[] = [];
  let reads = 0;
  const owner = make({ read: fd => { reads++; return fs.readFileSync(fd); }, close: fd => {
    attempts.push(fd);
    release(fd);
  } });
  owner.appendNative(A);
  const first = owner.checkpointEvidence();
  expect(first).toMatchObject({ generation: 7, format: input.format, observedBytes: 5, writtenBytes: 5, fault: false,
    writerPhase: "owned-open", closureStatus: "owned-open", temporaryReaderClosureStatus: "closed" });
  expect(first.raw).toEqual({ kind: "verified", path: owner.path, verifiedBytes: 5, sha256: hash(fs.readFileSync(owner.path)) });
  expect(live.has(opened[0]!)).toBe(true);
  owner.appendNative(B);
  const second = owner.checkpointEvidence();
  const repeated = owner.checkpointEvidence();
  const bytes = Buffer.concat([A, B]);
  expect(fs.readFileSync(owner.path)).toEqual(bytes);
  expect(second).toMatchObject({ observedBytes: 8, writtenBytes: 8, format: input.format, generation: 7 });
  expect(second.raw).toEqual({ kind: "verified", path: owner.path, verifiedBytes: 8, sha256: hash(bytes) });
  expect(repeated).toEqual(second);
  expect(reads).toBe(3);
  expect(attempts).toEqual(opened.slice(1));
  expect(opened.length).toBe(4);
  const final = owner.close();
  expect(final).toMatchObject({ observedBytes: 8, writtenBytes: 8, raw: second.raw, closureStatus: "closed", fault: false });
  expect(owner.close()).toBe(final);
  expect(() => owner.appendNative(B)).toThrow();
  expect(() => owner.checkpointEvidence()).toThrow();
  expect(first).toMatchObject({ observedBytes: 5, writtenBytes: 5, raw: { verifiedBytes: 5, sha256: hash(A) }, errors: [] });
  expect(attempts).toEqual([...opened.slice(1), opened[0]!]);
});

test.each(["throw", "zero", "negative", "oversized", "nan", "infinity", "fraction"])("immediate %s append fault requires no read or close and never resets", fault => {
  let writes = 0, reads = 0, closes = 0;
  const owner = make({ write: (fd, bytes, offset, length, position) => {
    writes++;
    if (writes === 3) {
      if (fault === "throw") throw new Error("append failed now");
      return { zero: 0, negative: -1, oversized: length + 1, nan: NaN, infinity: Infinity, fraction: 0.5 }[fault]!;
    }
    return fs.writeSync(fd, bytes, offset, writes === 2 ? 1 : length, position);
  }, read: fd => { reads++; return fs.readFileSync(fd); }, close: fd => { closes++; release(fd); } });
  owner.appendNative(A);
  const before = owner.observe();
  owner.appendNative(B);
  expect(owner.observe()).toEqual({ observedBytes: 8, writtenBytes: 6, appendFault: true, fault: true,
    writerPhase: "owned-open", closureStatus: "owned-open" });
  owner.appendNative(Buffer.from([77, 78]));
  expect(owner.observe()).toMatchObject({ observedBytes: 10, writtenBytes: 6, appendFault: true });
  expect({ writes, reads, closes }).toEqual({ writes: 3, reads: 0, closes: 0 });
  expect(before).toMatchObject({ observedBytes: 5, writtenBytes: 5, appendFault: false, fault: false });
  const prefix = Buffer.concat([A, B.subarray(0, 1)]);
  expect(fs.readFileSync(owner.path)).toEqual(prefix);
  expect(owner.checkpointEvidence()).toMatchObject({ fault: true, appendFault: true, raw: { verifiedBytes: 6, sha256: hash(prefix) } });
  owner.close();
  expect(owner.observe()).toMatchObject({ writerPhase: "terminal", closureStatus: "closed", appendFault: true });
});

test.each(["read", "open", "replace", "truncate", "overwrite", "directory", "writer-mode", "reader-identity", "during-read"])("live snapshot refuses %s verification failure and retains the take", fault => {
  const foreign = join(root, "foreign-reader");
  fs.writeFileSync(foreign, B, { mode: 0o600 });
  const owner = make({ open: (path, flags, mode) => {
    if (typeof flags === "number" && fault === "open") throw new Error("reader open failed");
    return acquire(typeof flags === "number" && fault === "reader-identity" ? foreign : path, flags, mode);
  }, read: fd => {
    if (fault === "read") throw new Error("snapshot read failed");
    const bytes = fs.readFileSync(fd);
    if (fault === "during-read") fs.writeFileSync(owner.path, Buffer.alloc(5, 88));
    return bytes;
  } });
  owner.appendNative(A);
  if (fault === "replace") {
    fs.renameSync(owner.path, owner.path + ".original");
    fs.writeFileSync(owner.path, A, { mode: 0o600 });
  }
  if (fault === "truncate") fs.truncateSync(owner.path, 2);
  if (fault === "overwrite") fs.writeFileSync(owner.path, Buffer.alloc(5, 88));
  if (fault === "writer-mode") fs.chmodSync(owner.path, 0o644);
  if (fault === "directory") {
    fs.renameSync(dirname(owner.path), dirname(owner.path) + ".original");
    fs.mkdirSync(dirname(owner.path), { mode: 0o700 });
    fs.writeFileSync(owner.path, A, { mode: 0o600 });
  }
  const snapshot = owner.checkpointEvidence();
  expect(snapshot).toMatchObject({ observedBytes: 5, writtenBytes: 5, fault: true, writerPhase: "owned-open",
    closureStatus: "owned-open", raw: { kind: "unavailable", verifiedBytes: null } });
  expect(snapshot.errors.some(error => error.stage === "verify")).toBe(true);
  expect(live.has(opened[0]!)).toBe(true);
  expect(fs.existsSync(owner.path)).toBe(true);
  expect(owner.close()).toMatchObject({ fault: true, closureStatus: "closed" });
});

test("live zero is verified but observed lost bytes are unavailable", () => {
  const empty = make();
  expect(empty.checkpointEvidence()).toMatchObject({ observedBytes: 0, writtenBytes: 0,
    raw: { kind: "verified", verifiedBytes: 0, sha256: hash(Buffer.alloc(0)) }, writerPhase: "owned-open" });
  const lost = make({ write: () => { throw new Error("nothing written"); } });
  lost.appendNative(A);
  expect(fs.readFileSync(lost.path)).toEqual(Buffer.alloc(0));
  expect(lost.checkpointEvidence()).toMatchObject({ observedBytes: 5, writtenBytes: 0, appendFault: true,
    temporaryReaderClosureStatus: "not-opened", raw: { kind: "unavailable", verifiedBytes: null } });
});

test("later append errors and observations cannot change an earlier raw snapshot", () => {
  let writes = 0;
  const owner = make({ write: (fd, bytes, offset, length, position) => {
    if (++writes > 1) throw new Error("later append failed");
    return fs.writeSync(fd, bytes, offset, length, position);
  } });
  owner.appendNative(A);
  const first = owner.checkpointEvidence();
  owner.appendNative(B);
  expect(owner.checkpointEvidence()).toMatchObject({ observedBytes: 8, writtenBytes: 5, appendFault: true, fault: true,
    raw: { verifiedBytes: 5, sha256: hash(A) } });
  expect(first).toMatchObject({ observedBytes: 5, writtenBytes: 5, appendFault: false, fault: false, errors: [] });
  expect(first.raw).toMatchObject({ verifiedBytes: 5, sha256: hash(A) });
});

test("recovered byte facts do not erase verification faults or mutate earlier diagnostics", () => {
  let fail = false;
  const owner = make({ read: fd => {
    if (fail) throw new Error("transient read failure");
    return fs.readFileSync(fd);
  } });
  owner.appendNative(A);
  const clean = owner.checkpointEvidence();
  fail = true;
  const failed = owner.checkpointEvidence();
  fail = false;
  owner.appendNative(B);
  expect(owner.checkpointEvidence()).toMatchObject({ fault: true, raw: { verifiedBytes: 8, sha256: hash(Buffer.concat([A, B])) } });
  expect(clean.errors).toEqual([]);
  expect(clean.fault).toBe(false);
  expect(failed.errors.length).toBe(1);
  expect(failed).toMatchObject({ observedBytes: 5, writtenBytes: 5, raw: { kind: "unavailable" } });
  expect(owner.close()).toMatchObject({ fault: true, closureStatus: "closed" });
});

test.each(["before", "after", "persistent", "different-file", "same-inode"])("snapshot reader close %s remains ambiguous through later snapshots and terminal close", fault => {
  const attempts: number[] = [];
  const replacements: { fd: number; original: number; identity: fs.Stats; bytes: Buffer }[] = [];
  const owner = make({ close: fd => {
    attempts.push(fd);
    if (fd === opened[0] || (fault !== "persistent" && attempts.length > 1)) return release(fd);
    if (fault === "before" || fault === "persistent") ambiguous.add(fd);
    else release(fd);
    if (fault === "same-inode" || fault === "different-file") {
      const path = fault === "same-inode" ? owner.path : join(root, "replacement");
      if (fault === "different-file") fs.writeFileSync(path, B, { mode: 0o600 });
      const identity = fs.statSync(path);
      const replacement = acquire(path, "r");
      ambiguous.add(replacement);
      replacements.push({ fd: replacement, original: fd, identity, bytes: fault === "same-inode" ? A : B });
    }
    throw new Error("ambiguous reader close");
  } });
  const unrelated = acquire(join(root, "unaffected"), "w+", 0o600);
  fs.writeSync(unrelated, B, 0, B.length, 0);
  try {
    owner.appendNative(A);
    const first = owner.checkpointEvidence();
    expect(first).toMatchObject({ writerPhase: "owned-open", closureStatus: "unconfirmed", temporaryReaderClosureStatus: "unconfirmed",
      fault: true, raw: { verifiedBytes: 5, sha256: hash(A) } });
    expect(owner.observe()).toMatchObject({ writerPhase: "owned-open", closureStatus: "unconfirmed", appendFault: false });
    const second = owner.checkpointEvidence();
    expect(second).toMatchObject({ closureStatus: "unconfirmed", fault: true, raw: first.raw,
      temporaryReaderClosureStatus: fault === "persistent" ? "unconfirmed" : "closed" });
    const final = owner.close();
    expect(final).toMatchObject({ closureStatus: "unconfirmed", fault: true, raw: first.raw });
    expect(owner.close()).toBe(final);
    expect(owner.observe()).toMatchObject({ writerPhase: "terminal", closureStatus: "unconfirmed" });
    expect(attempts.length).toBe(4);
    expect(attempts.filter(fd => fd === opened[0]).length).toBe(1);
    expect(live.has(opened[0]!)).toBe(false);
    expect(first.errors.length).toBe(1);
    expect(String(first.errors[0]?.cause)).toBe("Error: ambiguous reader close");
    for (const item of replacements) {
      expect(item.fd).toBe(item.original);
      expect(fs.fstatSync(item.fd)).toMatchObject({ dev: item.identity.dev, ino: item.identity.ino, mode: item.identity.mode,
        size: item.identity.size, ctimeMs: item.identity.ctimeMs, mtimeMs: item.identity.mtimeMs });
      expect(fs.readFileSync(item.fd)).toEqual(item.bytes);
    }
    for (const fd of ambiguous) expect(fs.fstatSync(fd).isFile()).toBe(true);
    expect(fs.readFileSync(unrelated)).toEqual(B);
  } finally { release(unrelated); }
  expect(fs.readFileSync(owner.path)).toEqual(A);
});
