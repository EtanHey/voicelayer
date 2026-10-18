import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { createHash } from "crypto";

// T3GATE1 (2026-10-18): the 2.2.45 T3 Option+F5 regression shipped because publication never
// required the installed-candidate T3 proof. The tap-check (final, pre-cask-bump) mode of
// scripts/verify-voicebar-release.sh now refuses without a matching proof, with no bypass.
// The proof is produced from the installed app's real artifacts by scripts/t3-optf5-proof.ts,
// which never presses keys itself.

const SUBPROCESS_TEST_TIMEOUT_MS = 15_000;

const repoRoot = new URL("../..", import.meta.url).pathname;
const verifyScript = join(repoRoot, "scripts", "verify-voicebar-release.sh");
const proofScript = join(repoRoot, "scripts", "t3-optf5-proof.ts");
const releaseScript = join(repoRoot, "scripts", "release-voicebar.sh");
const uploadScript = join(repoRoot, "scripts", "upload-voicebar-release.sh");
const version: string = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;

const COMMIT = "05bcc0a235712245dfc0bd08f8e657dd9277e7cd";
const OTHER_COMMIT = "1111111111111111111111111111111111111111";
const BUILD_TIME = "2026-10-18T01:10:14Z";
const AFTER_BUILD = "2026-10-18T01:30:00.000Z";
const BEFORE_BUILD = "2026-10-18T00:59:00.000Z";
const SYNTHETIC = "T3 gate synthetic paragraph seven, amber lantern.";
const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
const UUID = "73C05ACC-9C3D-432A-BEE4-A6F6B662954F";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "t3gate-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeInfoPlist(path: string, fields: Record<string, string>) {
  const body = Object.entries(fields)
    .map(([k, v]) => `  <key>${k}</key>\n  <string>${v}</string>`)
    .join("\n");
  writeFileSync(
    path,
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${body}\n</dict>\n</plist>\n`,
  );
}

function makeApp(root: string, commit = COMMIT, buildTime = BUILD_TIME) {
  const app = join(root, "VoiceBar.app");
  mkdirSync(join(app, "Contents", "Resources"), { recursive: true });
  writeInfoPlist(join(app, "Contents", "Info.plist"), {
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    GitCommit: commit,
    BuildTimeUTC: buildTime,
  });
  writeFileSync(join(app, "Contents", "Resources", "package.json"), JSON.stringify({ version }));
  return app;
}

function zipApp(root: string) {
  rmSync(join(root, "VoiceBar.zip"), { force: true });
  const r = Bun.spawnSync(["zip", "-qry", "VoiceBar.zip", "VoiceBar.app"], { cwd: root, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`zip failed: ${r.stderr}`);
  return createHash("sha256").update(readFileSync(join(root, "VoiceBar.zip"))).digest("hex");
}

function writeCask(sha: string) {
  writeFileSync(join(dir, "tap", "Casks", "voicebar.rb"), `cask "voicebar" do\n  version "${version}"\n  sha256 "${sha}"\nend\n`);
}

function makeReleaseFixture() {
  const app = makeApp(dir);
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  writeFileSync(join(app, "Contents", "MacOS", "VoiceBar"), "candidate-binary\n");
  const zipSha = zipApp(dir);
  mkdirSync(join(dir, "tap", "Formula"), { recursive: true });
  mkdirSync(join(dir, "tap", "Casks"), { recursive: true });
  writeFileSync(
    join(dir, "tap", "Formula", "voicelayer.rb"),
    `class Voicelayer < Formula\n  url "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-${version}.tgz"\nend\n`,
  );
  writeCask(zipSha);
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "codesign"),
    `#!/usr/bin/env bash
case "$*" in
  *-dvvv*) printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\\nTeamIdentifier=PPN23G925Y\\nRuntime Version=14.0.0\\n' >&2 ;;
  *-r-*) printf 'designated => certificate leaf[subject.OU] = "PPN23G925Y"\\n' >&2 ;;
  *) exit 2 ;;
esac
`,
  );
  writeFileSync(join(bin, "xcrun"), "#!/usr/bin/env bash\n[[ \"$1\" == stapler ]] && exit 0\nexit 2\n");
  writeFileSync(join(bin, "xattr"), "#!/usr/bin/env bash\nexit 0\n");
  for (const tool of ["codesign", "xcrun", "xattr"]) chmodSync(join(bin, tool), 0o755);
  return app;
}

function proof(overrides: Record<string, unknown> = {}) {
  return {
    schema: "voicelayer.t3-optf5-proof.v1",
    gitCommit: COMMIT,
    buildTimeUTC: BUILD_TIME,
    t3Build: "T3 Code (Alpha) 0.0.45 (0.0.45)",
    timestamp: AFTER_BUILD,
    expectedTextSha256: sha256(SYNTHETIC),
    historyTextSha256: sha256(SYNTHETIC),
    speakTextCommandId: UUID,
    readError: false,
    ...overrides,
  };
}

function writeProof(value: unknown) {
  const path = join(dir, "t3-proof.json");
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value, null, 2));
  return path;
}

function runVerify(args: string[], env: Record<string, string> = {}) {
  const result = Bun.spawnSync(
    [
      "bash",
      verifyScript,
      "--version",
      version,
      "--app",
      join(dir, "VoiceBar.app"),
      "--zip",
      join(dir, "VoiceBar.zip"),
      "--tap-root",
      join(dir, "tap"),
      ...args,
    ],
    {
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, PATH: `${join(dir, "bin")}:${process.env.PATH}`, ...env },
    },
  );
  return { code: result.exitCode, out: result.stdout.toString(), err: result.stderr.toString() };
}

describe("release delivery refuses without a matching T3 Option+F5 proof", () => {
  test("no proof: the final (cask-bump) verification refuses", () => {
    makeReleaseFixture();
    const r = runVerify([]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
    expect(r.out).not.toContain("PASS");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("no proof: there is no bypass environment variable", () => {
    makeReleaseFixture();
    for (const name of [
      "VOICEBAR_SKIP_T3_PROOF",
      "VOICEBAR_ALLOW_MISSING_T3_PROOF",
      "VOICEBAR_T3_PROOF_BYPASS",
      "T3_PROOF_BYPASS",
      "SKIP_T3_PROOF",
    ]) {
      const r = runVerify([], { [name]: "1" });
      expect(r.code).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("missing proof file refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", join(dir, "absent.json")]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("wrong GitCommit refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("GitCommit");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("expected/history hash mismatch refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ historyTextSha256: sha256("something else") }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("stale proof (older than the candidate build) refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ timestamp: BEFORE_BUILD }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("stale");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("readError, missing UUID, missing T3 build, bad schema and garbage all refuse", () => {
    makeReleaseFixture();
    const bad: unknown[] = [
      proof({ readError: true }),
      proof({ readError: "false" }),
      proof({ speakTextCommandId: "" }),
      proof({ speakTextCommandId: "not-a-uuid" }),
      proof({ t3Build: "" }),
      proof({ schema: "something-else" }),
      proof({ expectedTextSha256: "abc", historyTextSha256: "abc" }),
      proof({ timestamp: "yesterday" }),
      "{not json",
    ];
    for (const value of bad) {
      const r = runVerify(["--t3-proof", writeProof(value)]);
      expect(r.code).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a candidate without GitCommit or BuildTimeUTC cannot be matched and refuses", () => {
    makeReleaseFixture();
    writeInfoPlist(join(dir, "VoiceBar.app", "Contents", "Info.plist"), {
      CFBundleShortVersionString: version,
      CFBundleVersion: version,
    });
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("proof whose buildTimeUTC differs from the candidate (same commit rebuilt) refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ buildTimeUTC: "2026-10-18T01:09:00Z" }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("BuildTimeUTC");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP that does not contain the proven app refuses", () => {
    makeReleaseFixture();
    // Same version, different build inside the distributable.
    const other = mkdtempSync(join(dir, "other-"));
    makeApp(other, OTHER_COMMIT);
    mkdirSync(join(other, "VoiceBar.app", "Contents", "MacOS"), { recursive: true });
    writeFileSync(join(other, "VoiceBar.app", "Contents", "MacOS", "VoiceBar"), "other-binary\n");
    writeCask(zipApp(other));
    writeFileSync(join(dir, "VoiceBar.zip"), readFileSync(join(other, "VoiceBar.zip")));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("VoiceBar.zip");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP whose bundled daemon source differs from the proven app refuses", () => {
    makeReleaseFixture();
    const src = join(dir, "VoiceBar.app", "Contents", "Resources", "src");
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "mcp-server-daemon.ts"), "export const proven = true;\n");
    zipApp(dir);
    writeFileSync(join(src, "mcp-server-daemon.ts"), "export const proven = false;\n");
    writeCask(createHash("sha256").update(readFileSync(join(dir, "VoiceBar.zip"))).digest("hex"));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("mcp-server-daemon.ts");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP with an extra file the proven app lacks refuses", () => {
    makeReleaseFixture();
    writeFileSync(join(dir, "VoiceBar.app", "Contents", "Resources", "extra.js"), "1\n");
    zipApp(dir);
    rmSync(join(dir, "VoiceBar.app", "Contents", "Resources", "extra.js"));
    writeCask(createHash("sha256").update(readFileSync(join(dir, "VoiceBar.zip"))).digest("hex"));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("extra.js");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a cask sha256 that is not the ZIP's refuses", () => {
    makeReleaseFixture();
    writeCask("0".repeat(64));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("valid matching proof passes", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain("T3 Option+F5 proof");
    expect(r.out).toContain("PASS");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("artifact-only mode (--skip-tap-check) without a proof is not delivery and passes", () => {
    makeReleaseFixture();
    const r = runVerify(["--skip-tap-check"]);
    expect(r.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("artifact-only mode still checks a proof when one is given", () => {
    makeReleaseFixture();
    const r = runVerify(["--skip-tap-check", "--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("release-voicebar.sh refuses --upload: a fresh build can never carry a proof", () => {
    // The bad --version makes any script that does not refuse --upload at parse time exit at the
    // version check, before build-app.sh. Never run this script without a pre-build exit.
    const r = Bun.spawnSync(["bash", releaseScript, "--upload", "--skip-tap-check", "--version", "0.0.0-never"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr.toString()).toContain("upload-voicebar-release.sh");
    expect(r.stdout.toString()).not.toContain("Building notarized");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("release-voicebar.sh forwards --t3-proof to the verifier", () => {
    const text = readFileSync(releaseScript, "utf8");
    expect(text).toMatch(/VERIFY_ARGS\+=\(--t3-proof/);
  });

  test("CI publication does not depend on native T3 proof", () => {
    const publish = readFileSync(join(repoRoot, ".github", "workflows", "publish.yml"), "utf8");
    expect(publish).not.toContain("t3-proof");
    expect(publish).not.toContain("t3-optf5");
  });
});

describe("the release asset upload requires the proof", () => {
  function runUpload(args: string[]) {
    const ghLog = join(dir, "gh.log");
    writeFileSync(join(dir, "bin", "gh"), `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${ghLog}"\n`);
    chmodSync(join(dir, "bin", "gh"), 0o755);
    const r = Bun.spawnSync(
      ["bash", uploadScript, "--version", version, "--app", join(dir, "VoiceBar.app"), "--zip", join(dir, "VoiceBar.zip"), ...args],
      { stdout: "pipe", stderr: "pipe", env: { ...process.env, PATH: `${join(dir, "bin")}:${process.env.PATH}` } },
    );
    return { code: r.exitCode, err: r.stderr.toString(), gh: existsSync(ghLog) ? readFileSync(ghLog, "utf8") : "" };
  }

  test("no proof: nothing is uploaded", () => {
    makeReleaseFixture();
    const r = runUpload([]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
    expect(r.gh).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("mismatched proof: nothing is uploaded", () => {
    makeReleaseFixture();
    const r = runUpload(["--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
    expect(r.gh).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("valid proof: uploads exactly the verified ZIP", () => {
    makeReleaseFixture();
    const r = runUpload(["--t3-proof", writeProof(proof())]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.gh).toContain(`release upload v${version} ${join(dir, "VoiceBar.zip")}`);
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

// ---- proof producer ------------------------------------------------------------------------

const captureLine = (pid: number, ms: number, outcome = "completed", app = "com.t3tools.t3code", utf16 = SYNTHETIC.length) =>
  `${localStamp(ms)} VoiceBar[${pid}:97212876] [VoiceBar][diag] selection_capture appActive=false appKeyWindowTitle=not_recorded ax_read=${outcome === "completed" ? "text" : "not_attempted"} frontmostApp=${app} host_structure=not_observed line_breaks=0 outcome=${outcome} path=ax utf16_count=${utf16} voiceMode=idle`;
const speakLine = (id: string) =>
  `[socket-client] Command from VoiceBar: {"cmd":"speak_text","id":"${id}"} bytes=176`;

function localStamp(ms: number) {
  // VoiceBar's NSLog prefix is local wall-clock time.
  const d = new Date(ms);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

const sleepSync = (ms: number) => Bun.sleepSync(ms);

// A real running "installed VoiceBar": a symlink to bash at <app>/Contents/MacOS/VoiceBar, so
// `ps` shows the bundle executable path, with a child whose command names mcp-server-daemon.
// The child is `exec -a`'d sleep, so the fixture tree is exactly two processes, no grandchild.
// Started more than a second after the bundle was written, like a relaunch after install.
function launchFakeVoiceBar(app: string, interpreter = "/bin/bash") {
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  symlinkSync(interpreter, join(app, "Contents", "MacOS", "VoiceBar"));
  const proc = Bun.spawn(
    [join(app, "Contents", "MacOS", "VoiceBar"), "-c", "(exec -a mcp-server-daemon /bin/sleep 120) & wait"],
    { stdout: "ignore", stderr: "ignore" },
  );
  sleepSync(300); // let the daemon-like child appear
  return proc;
}

async function stopFakeVoiceBar(proc: ReturnType<typeof Bun.spawn>) {
  const children = Bun.spawnSync(["pgrep", "-P", String(proc.pid)], { stdout: "pipe" })
    .stdout.toString()
    .split("\n")
    .filter(Boolean)
    .map(Number);
  for (const child of children) process.kill(child, "SIGKILL");
  proc.kill("SIGKILL");
  await proc.exited;
  for (const child of children) {
    while (Bun.spawnSync(["kill", "-0", String(child)]).exitCode === 0) sleepSync(20);
  }
}

let runtimeRoot: string;
let installedApp: string;
let voiceBar: ReturnType<typeof Bun.spawn>;

beforeAll(() => {
  runtimeRoot = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "t3rt-"));
  installedApp = makeApp(join(runtimeRoot, "installed"));
  sleepSync(1_100); // process start must be a whole second after the install
  voiceBar = launchFakeVoiceBar(installedApp);
});
afterAll(async () => {
  await stopFakeVoiceBar(voiceBar);
  rmSync(runtimeRoot, { recursive: true, force: true });
});

function producerFixture(app = installedApp) {
  const t3 = join(dir, "T3 Code (Alpha).app");
  mkdirSync(join(t3, "Contents"), { recursive: true });
  writeInfoPlist(join(t3, "Contents", "Info.plist"), {
    CFBundleIdentifier: "com.t3tools.t3code",
    CFBundleName: "T3 Code (Alpha)",
    CFBundleShortVersionString: "0.0.45",
    CFBundleVersion: "0.0.45",
  });
  // A complete, valid keypress from BEFORE start: it must never count.
  const earlier = Date.now() - 60_000;
  const log = join(dir, "voicebar-err.log");
  writeFileSync(log, `${captureLine(voiceBar.pid, earlier)}\n${speakLine("00000000-0000-4000-8000-000000000000")}\n`);
  const history = join(dir, "voicelayer-history.json");
  writeFileSync(history, JSON.stringify([{ id: 0, file: "x.mp3", text: SYNTHETIC, voice: "v", timestamp: earlier + 400 }]));
  const expected = join(dir, "expected.txt");
  writeFileSync(expected, SYNTHETIC);
  const state = join(dir, "state.json");
  const out = join(dir, "proof.json");
  return { installed: app, t3, log, history, expected, state, out };
}

function runProducer(args: string[]) {
  // bun test runs in UTC; the producer parses VoiceBar's local-time log prefix, so pin both.
  const r = Bun.spawnSync([process.execPath, proofScript, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, TZ: "Etc/UTC" },
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

function start(f: ReturnType<typeof producerFixture>) {
  return runProducer([
    "start",
    "--state", f.state,
    "--app", f.installed,
    "--t3-app", f.t3,
    "--voicebar-log", f.log,
    "--history-file", f.history,
    "--expected-text-file", f.expected,
  ]);
}

function finish(f: ReturnType<typeof producerFixture>) {
  return runProducer(["finish", "--state", f.state, "--out", f.out]);
}

function simulateKeypress(
  f: ReturnType<typeof producerFixture>,
  opts: { outcome?: string; app?: string; pid?: number; ids?: string[]; text?: string; utf16?: number; speakBeforeCapture?: boolean } = {},
) {
  const now = Date.now();
  const capture = captureLine(opts.pid ?? voiceBar.pid, now, opts.outcome, opts.app, opts.utf16);
  const speaks = (opts.ids ?? [UUID]).map(speakLine);
  const lines = opts.speakBeforeCapture ? [...speaks, capture] : [capture, ...speaks];
  writeFileSync(f.log, readFileSync(f.log, "utf8") + lines.join("\n") + "\n");
  const history = JSON.parse(readFileSync(f.history, "utf8"));
  if (opts.text !== undefined || opts.ids?.length !== 0) {
    history.push({ id: 1, file: "y.mp3", text: opts.text ?? SYNTHETIC, voice: "v", timestamp: now + 400 });
  }
  writeFileSync(f.history, JSON.stringify(history));
}

describe("t3-optf5-proof producer reads the installed app's real artifacts", () => {
  test("start + operator keypress + finish yields a proof the release gate accepts", () => {
    const f = producerFixture();
    const s = start(f);
    expect(s.err).toBe("");
    expect(s.code).toBe(0);
    simulateKeypress(f);
    const r = finish(f);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    const p = JSON.parse(readFileSync(f.out, "utf8"));
    expect(p).toMatchObject({
      schema: "voicelayer.t3-optf5-proof.v1",
      gitCommit: COMMIT,
      buildTimeUTC: BUILD_TIME,
      expectedTextSha256: sha256(SYNTHETIC),
      historyTextSha256: sha256(SYNTHETIC),
      speakTextCommandId: UUID,
      readError: false,
    });
    expect(p.t3Build).toContain("0.0.45");
    expect(JSON.stringify(p)).not.toContain(SYNTHETIC);

    makeReleaseFixture();
    const gate = runVerify(["--t3-proof", f.out]);
    expect(gate.err).toBe("");
    expect(gate.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a complete valid keypress logged before start is never counted", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("Option+F5 was not received");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture whose length is not the expected paragraph's is not this keypress", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { utf16: SYNTHETIC.length + 7 });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("utf16_count");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a speak_text from before the capture makes the window ambiguous", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { ids: [UUID], speakBeforeCapture: true });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a failed T3 read is a read error and exits non-zero", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { outcome: "capture_failed", ids: [] });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("read error");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("history text that differs from the expected paragraph exits non-zero and the gate refuses it", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { text: "T3 gate synthetic paragraph seven" });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
    makeReleaseFixture();
    expect(runVerify(["--t3-proof", f.out]).code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("two speak_text commands in one window are ambiguous and refuse", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { ids: [UUID, "758CE9C3-D434-4FEC-9B90-8173721553E0"] });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture from another frontmost app is not T3 proof", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { app: "com.apple.Safari" });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture logged by a different VoiceBar process is not proof for the installed app", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { pid: voiceBar.pid + 100_000 });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("VoiceBar");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("no running VoiceBar from the installed bundle refuses at start", () => {
    const notRunning = makeApp(join(dir, "not-running"));
    const f = producerFixture(notRunning);
    const r = start(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("running");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a VoiceBar process older than the installed bundle (swapped, not relaunched) refuses", async () => {
    const swapped = makeApp(join(dir, "swapped"));
    const old = launchFakeVoiceBar(swapped);
    try {
      sleepSync(1_100);
      // Re-install the bundle under the running process.
      writeInfoPlist(join(swapped, "Contents", "Info.plist"), {
        CFBundleShortVersionString: version,
        CFBundleVersion: version,
        GitCommit: COMMIT,
        BuildTimeUTC: BUILD_TIME,
      });
      const f = producerFixture(swapped);
      const r = start(f);
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("older than the installed bundle");
    } finally {
      await stopFakeVoiceBar(old);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("an old VoiceBar still running after a staged bundle was moved into place refuses", async () => {
    // Stage B first (its files' ctime predates the launch), launch A, then rename B over A.
    const root = mkdtempSync(join(dir, "swap-"));
    const staged = makeApp(join(root, "staged"));
    mkdirSync(join(staged, "Contents", "MacOS"), { recursive: true });
    symlinkSync("/bin/zsh", join(staged, "Contents", "MacOS", "VoiceBar"));
    const live = makeApp(join(root, "live"));
    sleepSync(1_100);
    const old = launchFakeVoiceBar(live);
    try {
      Bun.spawnSync(["mv", live, join(root, "live-old.app")]);
      Bun.spawnSync(["mv", staged, live]);
      const f = producerFixture(live);
      const r = start(f);
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("not the executable installed at");
    } finally {
      await stopFakeVoiceBar(old);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a T3 app that is not com.t3tools.t3code is refused at start", () => {
    const f = producerFixture();
    writeInfoPlist(join(f.t3, "Contents", "Info.plist"), { CFBundleIdentifier: "com.example.other", CFBundleShortVersionString: "1" });
    expect(start(f).code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the producer never synthesizes a keypress", () => {
    const text = readFileSync(proofScript, "utf8");
    for (const forbidden of ["CGEvent", "osascript", "key code", "keystroke", "cliclick", "hidutil"]) {
      expect(text).not.toContain(forbidden);
    }
  });
});
