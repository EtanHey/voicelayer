import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
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

function makeReleaseFixture() {
  const app = makeApp(dir);
  writeFileSync(join(dir, "VoiceBar.zip"), "zip-placeholder\n");
  mkdirSync(join(dir, "tap", "Formula"), { recursive: true });
  mkdirSync(join(dir, "tap", "Casks"), { recursive: true });
  writeFileSync(
    join(dir, "tap", "Formula", "voicelayer.rb"),
    `class Voicelayer < Formula\n  url "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-${version}.tgz"\nend\n`,
  );
  writeFileSync(join(dir, "tap", "Casks", "voicebar.rb"), `cask "voicebar" do\n  version "${version}"\nend\n`);
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

  test("valid matching proof passes", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain("T3 Option+F5 proof");
    expect(r.out).toContain("PASS");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("artifact-only mode (--skip-tap-check) is not delivery and needs no proof", () => {
    makeReleaseFixture();
    const r = runVerify(["--skip-tap-check"]);
    expect(r.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("release-voicebar.sh forwards --t3-proof to the verifier", () => {
    const text = readFileSync(releaseScript, "utf8");
    expect(text).toContain("--t3-proof");
    expect(text).toMatch(/VERIFY_ARGS\+=\(--t3-proof/);
  });

  test("CI publication does not depend on native T3 proof", () => {
    const publish = readFileSync(join(repoRoot, ".github", "workflows", "publish.yml"), "utf8");
    expect(publish).not.toContain("t3-proof");
    expect(publish).not.toContain("t3-optf5");
  });
});

// ---- proof producer ------------------------------------------------------------------------

const CAPTURE_OK =
  "2026-10-18 04:27:30.385 VoiceBar[77614:97212876] [VoiceBar][diag] selection_capture appActive=false appKeyWindowTitle=not_recorded ax_read=text frontmostApp=com.t3tools.t3code host_structure=not_observed line_breaks=0 outcome=completed path=ax utf16_count=50 voiceMode=idle";
const CAPTURE_FAILED =
  "2026-10-18 04:27:30.385 VoiceBar[77614:97212876] [VoiceBar][diag] selection_capture appActive=false appKeyWindowTitle=not_recorded ax_read=not_attempted frontmostApp=com.t3tools.t3code host_structure=not_observed outcome=capture_failed voiceMode=idle";
const speakLine = (id: string) =>
  `[socket-client] Command from VoiceBar: {"cmd":"speak_text","id":"${id}"} bytes=176`;

function localStamp(ms: number) {
  // VoiceBar's NSLog prefix is local wall-clock time.
  const d = new Date(ms);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function producerFixture() {
  const installed = makeApp(join(dir, "installed"));
  const t3 = join(dir, "T3 Code (Alpha).app");
  mkdirSync(join(t3, "Contents"), { recursive: true });
  writeInfoPlist(join(t3, "Contents", "Info.plist"), {
    CFBundleIdentifier: "com.t3tools.t3code",
    CFBundleName: "T3 Code (Alpha)",
    CFBundleShortVersionString: "0.0.45",
    CFBundleVersion: "0.0.45",
  });
  const log = join(dir, "voicebar-err.log");
  writeFileSync(log, `${speakLine("00000000-0000-0000-0000-000000000000")}\n${CAPTURE_OK}\n`);
  const history = join(dir, "voicelayer-history.json");
  writeFileSync(history, JSON.stringify([{ id: 0, file: "x.mp3", text: SYNTHETIC, voice: "v", timestamp: 1 }]));
  const expected = join(dir, "expected.txt");
  writeFileSync(expected, SYNTHETIC);
  const state = join(dir, "state.json");
  const out = join(dir, "proof.json");
  return { installed, t3, log, history, expected, state, out };
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
  opts: { capture?: string; ids?: string[]; text?: string; historyDelayMs?: number } = {},
) {
  const now = Date.now();
  const capture = (opts.capture ?? CAPTURE_OK).replace(/^\S+ \S+/, localStamp(now));
  const lines = [capture, ...(opts.ids ?? [UUID]).map(speakLine)];
  writeFileSync(f.log, readFileSync(f.log, "utf8") + lines.join("\n") + "\n");
  const history = JSON.parse(readFileSync(f.history, "utf8"));
  if (opts.text !== undefined || opts.ids?.length !== 0) {
    history.push({ id: 1, file: "y.mp3", text: opts.text ?? SYNTHETIC, voice: "v", timestamp: now + (opts.historyDelayMs ?? 400) });
  }
  writeFileSync(f.history, JSON.stringify(history));
}

describe("t3-optf5-proof producer reads the installed app's real artifacts", () => {
  test("start + operator keypress + finish yields a proof the release gate accepts", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f);
    const r = finish(f);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    const p = JSON.parse(readFileSync(f.out, "utf8"));
    expect(p).toMatchObject({
      schema: "voicelayer.t3-optf5-proof.v1",
      gitCommit: COMMIT,
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

  test("pre-existing log lines and history entries are never counted", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("speak_text");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a failed T3 read is recorded as readError=true and exits non-zero", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { capture: CAPTURE_FAILED, ids: [], text: undefined });
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
    simulateKeypress(f, { capture: CAPTURE_OK.replace("com.t3tools.t3code", "com.apple.Safari") });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
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
