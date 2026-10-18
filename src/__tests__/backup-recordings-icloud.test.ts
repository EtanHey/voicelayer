import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, utimesSync, symlinkSync, cpSync, realpathSync, openSync, closeSync } from "node:fs";
import { tmpdir, hostname } from "node:os";
import { join, resolve } from "node:path";

// Real subprocesses: standalone p95 <= 484 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

const script = resolve("scripts/backup-recordings-icloud.sh");
let home: string, source: string, dest: string, bin: string;
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "backup home & "));
  source = join(home, ".local/share/voicelayer/recordings");
  dest = join(home, "Library/Mobile Documents/com~apple~CloudDocs/VoiceLayer/recordings", hostname().split(".")[0]!);
  bin = join(home, "bin");
  mkdirSync(source, { recursive: true });
  mkdirSync(bin);
  mkdirSync(join(home, "Library/Mobile Documents/com~apple~CloudDocs"), { recursive: true });
  writeFileSync(join(bin, "launchctl"), `#!/bin/sh\ntouch "${home}/launchctl-called"\nexit 77\n`, { mode: 0o755 });
  space(100_000_000);
});
afterEach(() => rmSync(home, { recursive: true, force: true }));
function space(kb: number) {
  writeFileSync(join(bin, "df"), `#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\nfake 200000000 0 ${kb} 0%% /\\n'\n`, { mode: 0o755 });
}
function recording(name = "2026-10-14/session one", old = true) {
  const folder = join(source, name);
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "audio.wav"), "original audio");
  writeFileSync(join(folder, "meta.json"), "metadata");
  if (old) utimesSync(join(folder, "audio.wav"), 1_700_000_000, 1_700_000_000);
  return folder;
}
function run(...args: string[]) {
  const result = Bun.spawnSync(["bash", script, ...args], { env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}` } });
  if (result.exitCode !== 0) console.error(result.stdout.toString(), result.stderr.toString());
  return result;
}
test("append-only, spaces, unchanged reruns and changed versions", () => {
  const folder = recording();
  expect(run().exitCode).toBe(0);
  const backed = join(dest, "2026-10-14/session one");
  expect(readFileSync(join(backed, "audio.wav"), "utf8")).toBe("original audio");
  expect(run().exitCode).toBe(0);
  expect(readdirSync(backed).sort()).toEqual(["audio.wav", "meta.json"]);
  writeFileSync(join(folder, "audio.wav"), "modified audio"); // same size, different mtime
  utimesSync(join(folder, "audio.wav"), 1_700_000_001, 1_700_000_001);
  expect(run().exitCode).toBe(0);
  expect(readFileSync(join(backed, "audio.wav"), "utf8")).toBe("original audio");
  const version = readdirSync(backed).find(n => n.startsWith("audio.wav.changed-"))!;
  expect(readFileSync(join(backed, version), "utf8")).toBe("modified audio");
  expect(run().exitCode).toBe(0);
  expect(readdirSync(backed)).toHaveLength(3);
  rmSync(folder, { recursive: true });
  expect(run().exitCode).toBe(0);
  expect(readFileSync(join(backed, version), "utf8")).toBe("modified audio");
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("space guard includes pending copy and logs the skip", () => {
  recording();
  space(24_414_063); // 25 GB minus the bytes to copy is below the reserve
  expect(run().exitCode).toBe(0);
  expect(existsSync(dest)).toBe(false);
  expect(readFileSync(join(home, "Library/Logs/voicelayer/recordings-backup.log"), "utf8")).toContain("space guard");
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("skips active sessions but still backs up an older session on the same day", () => {
  recording("day/active", false);
  recording("day/stable");
  expect(run().exitCode).toBe(0);
  expect(existsSync(join(dest, "day/active"))).toBe(false);
  expect(existsSync(join(dest, "day/stable/audio.wav"))).toBe(true);
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("dry run creates neither backups nor logs", () => {
  recording();
  const before = readdirSync(home).sort();
  const result = run("--dry-run");
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString()).toContain("DRY RUN");
  expect(readdirSync(home).sort()).toEqual(before);
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("does not follow source or destination symlinks", () => {
  const folder = recording();
  const outside = join(home, "private");
  mkdirSync(outside);
  writeFileSync(join(outside, "secret"), "private");
  symlinkSync(outside, join(folder, "escape"));
  symlinkSync(join(outside, "secret"), join(folder, "linked"));
  expect(run().exitCode).toBe(0);
  expect(existsSync(join(dest, "2026-10-14/session one/escape"))).toBe(false);
  expect(existsSync(join(dest, "2026-10-14/session one/linked"))).toBe(false);
  rmSync(join(home, "Library/Mobile Documents"), { recursive: true });
  symlinkSync(outside, join(home, "Library/Mobile Documents"));
  expect(run().exitCode).not.toBe(0);
  expect(readdirSync(outside)).toEqual(["secret"]);
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("installer renders a nightly plist without loading or running it", () => {
  const result = Bun.spawnSync(["bash", resolve("launchd/install.sh"), "--recordings-backup"], {
    env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}` },
  });
  expect(result.exitCode).toBe(0);
  const plist = readFileSync(join(home, "Library/LaunchAgents/com.voicelayer.recordings-backup.plist"), "utf8");
  expect(plist).toContain("<integer>2</integer>");
  expect(plist).not.toContain("__BACKUP_SCRIPT__");
  expect(plist).not.toContain("RunAtLoad");
  expect(existsSync(join(home, "launchctl-called"))).toBe(false);
  expect(existsSync(dest)).toBe(false);
}, SUBPROCESS_TEST_TIMEOUT_MS);

function installLayout(relative: string, viaOpt = false) {
  const root = join(home, relative);
  mkdirSync(join(root, "scripts"), { recursive: true });
  mkdirSync(join(root, "launchd"));
  for (const file of ["scripts/backup-recordings-icloud.sh", "launchd/install.sh", "launchd/com.voicelayer.recordings-backup.plist"]) {
    cpSync(resolve(file), join(root, file));
  }
  const opt = join(realpathSync(home), "brew/opt/voicelayer");
  if (relative.startsWith("brew/Cellar/")) {
    mkdirSync(join(home, "brew/opt"), { recursive: true });
    symlinkSync(join(home, "brew/Cellar/voicelayer/2.2.44"), opt);
  }
  const result = Bun.spawnSync(["bash", join(viaOpt ? join(opt, "libexec") : root, "launchd/install.sh"), "--recordings-backup"], {
    env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}` },
  });
  expect(result.exitCode).toBe(0);
  const parsed = Bun.spawnSync(["python3", "-c", "import json, plistlib, sys; print(json.dumps(plistlib.load(open(sys.argv[1], 'rb'))))",
    join(home, "Library/LaunchAgents/com.voicelayer.recordings-backup.plist")], { env: process.env });
  expect(parsed.exitCode).toBe(0);
  expect(existsSync(join(home, "launchctl-called"))).toBe(false);
  expect(existsSync(dest)).toBe(false);
  return { root, opt, config: JSON.parse(parsed.stdout.toString()) as { ProgramArguments: string[]; StandardErrorPath: string } };
}

for (const viaOpt of [false, true]) {
  test(`Cellar installer renders stable opt path (invoked via ${viaOpt ? "symlink" : "keg"}) and survives upgrade`, () => {
    const { root, opt, config } = installLayout("brew/Cellar/voicelayer/2.2.44/libexec", viaOpt);
    // The fake opt points at the formula root, as Homebrew does, not libexec.
    expect(config.ProgramArguments).toEqual(["/bin/bash", join(opt, "libexec/scripts/backup-recordings-icloud.sh")]);
    rmSync(join(home, "brew/Cellar/voicelayer/2.2.44"), { recursive: true });
    rmSync(opt);
    const next = root.replace("2.2.44", "2.2.45");
    mkdirSync(join(next, "scripts"), { recursive: true });
    writeFileSync(join(next, "scripts/backup-recordings-icloud.sh"), "printf 'upgraded job ran\\n'\n");
    symlinkSync(join(home, "brew/Cellar/voicelayer/2.2.45"), opt);
    const job = Bun.spawnSync(config.ProgramArguments, { env: process.env });
    expect(job.exitCode).toBe(0);
    expect(job.stdout.toString()).toBe("upgraded job ran\n");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
}

test("checkout installer keeps its checkout script path", () => {
  const { root, config } = installLayout("checkout");
  expect(config.ProgramArguments).toEqual(["/bin/bash", join(realpathSync(root), "scripts/backup-recordings-icloud.sh")]);
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("missing scheduled script fails nonzero and records Bash's error in the configured log", () => {
  const { root, config } = installLayout("checkout");
  expect(config.StandardErrorPath).toBe(join(realpathSync(home), "Library/Logs/voicelayer/recordings-backup.log"));
  rmSync(join(root, "scripts/backup-recordings-icloud.sh"));
  // Emulate launchd's stderr redirection without loading a real LaunchAgent.
  const stderr = openSync(config.StandardErrorPath, "a");
  try {
    expect(Bun.spawnSync(config.ProgramArguments, { env: process.env, stderr }).exitCode).not.toBe(0);
  } finally {
    closeSync(stderr);
  }
  const log = readFileSync(config.StandardErrorPath, "utf8");
  expect(log).toContain("backup-recordings-icloud.sh");
  expect(log).toContain("No such file or directory");
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("failed transfers publish no partial files and preserve originals", () => {
  recording();
  writeFileSync(join(bin, "rsync"), '#!/bin/sh\nexit 23\n', { mode: 0o755 });
  expect(run().exitCode).toBe(1);
  expect(readdirSync(join(dest, "2026-10-14/session one"))).toEqual([]);
  expect(readFileSync(join(source, "2026-10-14/session one/audio.wav"), "utf8")).toBe("original audio");
}, SUBPROCESS_TEST_TIMEOUT_MS);
test("missing iCloud directory skips without creating a lookalike", () => {
  recording();
  rmSync(join(home, "Library/Mobile Documents"), { recursive: true });
  expect(run().exitCode).toBe(0);
  expect(existsSync(join(home, "Library/Mobile Documents"))).toBe(false);
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("exclusive publication never overwrites a file appearing during transfer", () => {
  const folder = recording();
  rmSync(join(folder, "meta.json")); // target audio regardless of directory order
  writeFileSync(join(bin, "rsync"), `#!/usr/bin/env python3
import pathlib, subprocess, sys
subprocess.run(["/bin/cp", "-p", sys.argv[-2], sys.argv[-1]], check=True)
staged = pathlib.Path(sys.argv[-1])
(staged.parent.parent / pathlib.Path(sys.argv[-2]).name).write_text("racing writer")
`, { mode: 0o755 });
  expect(run().exitCode).toBe(1);
  expect(readFileSync(join(dest, "2026-10-14/session one/audio.wav"), "utf8")).toBe("racing writer");
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("copies nested session sidecars with the same relative tree", () => {
  const folder = recording();
  mkdirSync(join(folder, "chunks"));
  writeFileSync(join(folder, "chunks/part.json"), "timing");
  expect(run().exitCode).toBe(0);
  expect(readFileSync(join(dest, "2026-10-14/session one/chunks/part.json"), "utf8")).toBe("timing");
}, SUBPROCESS_TEST_TIMEOUT_MS);

for (const [label, payload] of [["short", "XX"], ["same-size wrong bytes", "X".repeat(14)]] as const) {
  test(`rejects a successful rsync with ${label} payload`, () => {
    const folder = recording();
    rmSync(join(folder, "meta.json")); // keep the injected payload audio-sized
    writeFileSync(join(bin, "rsync"), `#!/usr/bin/env python3
import os, pathlib, sys
src, staged = map(pathlib.Path, sys.argv[-2:])
staged.write_bytes(${JSON.stringify(payload)}.encode())
st = src.stat()
os.utime(staged, ns=(st.st_atime_ns, st.st_mtime_ns))
`, { mode: 0o755 });
    expect(run().exitCode).toBe(1);
    expect(readdirSync(join(dest, "2026-10-14/session one"))).toEqual([]);
    expect(readFileSync(join(folder, "audio.wav"), "utf8")).toBe("original audio");
    expect(readFileSync(join(home, "Library/Logs/voicelayer/recordings-backup.log"), "utf8")).toContain("verification failed");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
}

test("rejects a source changed during the byte comparison", () => {
  const folder = recording();
  rmSync(join(folder, "meta.json"));
  writeFileSync(join(bin, "cmp"), `#!/usr/bin/env python3
import os, sys
st = os.stat(sys.argv[-1])
os.utime(sys.argv[-1], ns=(st.st_atime_ns, st.st_mtime_ns + 1))
`, { mode: 0o755 });
  expect(run().exitCode).toBe(1);
  expect(readdirSync(join(dest, "2026-10-14/session one"))).toEqual([]);
  expect(readFileSync(join(home, "Library/Logs/voicelayer/recordings-backup.log"), "utf8")).toContain("source changed");
}, SUBPROCESS_TEST_TIMEOUT_MS);
