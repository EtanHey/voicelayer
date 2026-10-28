import { expect, spyOn, test } from "bun:test";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import { join } from "node:path";
import { atomicWriteFile, fsyncPath, recordingsArchiveRoot } from "../recordings-archive-fs";

// Preflight counterexamples only: these exercise existing archive primitives.
// They are deliberately RED, not acceptance tests for an implemented spool.
function fixture() {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") {
    throw new Error("Canonical test preload required");
  }
  const root = recordingsArchiveRoot();
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot || !root.startsWith(`${runRoot}/`)) {
    throw new Error("Archive must belong to this isolated run");
  }
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  return fs.mkdtempSync(join(root, "p4b-red-"));
}

function bytesEvidence(path: string) {
  const bytes = fs.readFileSync(path);
  return { bytes: [...bytes], sha256: createHash("sha256").update(bytes).digest("hex") };
}

test("RED: a shared atomic-write path cannot retain A after take B", () => {
  const directory = fixture();
  const path = join(directory, "native.pcm");
  const a = Buffer.from([1, 2, 3, 4, 5]); // Preserve the odd native tail.
  const b = Buffer.from([11, 12, 13]);
  try {
    atomicWriteFile(path, a);
    const first = bytesEvidence(path);
    expect(first.bytes).toEqual([...a]);
    atomicWriteFile(path, b);
    expect(bytesEvidence(path).bytes).toEqual([...b]); // Real write happened.
    expect(bytesEvidence(path)).toEqual(first);
  } finally {
    fs.rmSync(directory, { recursive: true });
  }
});

test("RED: best-effort directory sync cannot establish a strict checkpoint", () => {
  const directory = fixture();
  const path = join(directory, "native.pcm");
  const sync = fs.fsyncSync;
  const fault = new Error("synthetic directory sync failure");
  const attempted: number[] = [];
  let returnedNormally = false;
  let reported: unknown;
  atomicWriteFile(path, Buffer.from([21, 22, 23]));
  const original = bytesEvidence(path);
  const spy = spyOn(fs, "fsyncSync").mockImplementation((fd) => {
    if (fs.fstatSync(fd).isDirectory()) {
      attempted.push(fd);
      throw fault;
    }
    sync(fd);
  });
  try {
    try {
      fsyncPath(directory);
      returnedNormally = true;
    } catch (error) {
      reported = error;
    }
    expect(attempted).toHaveLength(1);
    expect(() => fs.fstatSync(attempted[0])).toThrow(); // Owned fd did close.
    expect(bytesEvidence(path)).toEqual(original); // Failure did not erase bytes.
    expect({ returnedNormally, reported }).toEqual({ returnedNormally: false, reported: fault });
  } finally {
    spy.mockRestore();
    fs.rmSync(directory, { recursive: true });
  }
});
