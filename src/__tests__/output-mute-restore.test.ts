import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, relative } from "path";

// MUTE1 (2026-10-19): Etan found his Mac muted and had not muted it. Any script or
// agent that mutes the host output must put back the state it found, on every exit.
// These tests never touch the real host mute: the static scan reads files, and the
// behaviour tests put a stateful osascript stub first on PATH.

const repo = join(import.meta.dir, "../..");
const SELF = relative(repo, import.meta.path);
const SUBPROCESS_TEST_TIMEOUT_MS = 20_000;

const CODE = /\.(sh|bash|zsh|ts|tsx|js|mjs|cjs|py|swift|applescript|scpt)$/;
const SKIP_DIRS = new Set([".build", "node_modules", "DerivedData", ".swiftpm", ".test-tmp"]);

// Fail closed: a file that writes the output mute or volume must be a reviewed writer with a
// behavioural restore test. Everything else mutes through scripts/lib/output-mute-guard.sh.
const REVIEWED_WRITERS: Record<string, string> = {
  "scripts/lib/output-mute-guard.sh": 'describe("output-mute-guard.sh restores the state it found")',
  "scripts/auto-f5-verify.sh": 'describe("auto-f5-verify.sh restores the volume and mute it found")',
};
// Matched on lowercased, whitespace-collapsed text, so `set  volume` or `SET VOLUME` still count.
// Read-only queries such as `output muted of (get volume settings)` match none of these.
const MUTE_WRITE = /\bset ?volume\b|output muted (true|false)\b|\b(with|without) output muted\b/;
const normalize = (text: string) => text.toLowerCase().replace(/\s+/g, " ");
const writesMute = (text: string) => MUTE_WRITE.test(normalize(text));
const offenders = (files: { path: string; text: string }[]) =>
  files.filter((f) => writesMute(f.text) && !(f.path in REVIEWED_WRITERS)).map((f) => f.path);

function codeFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...codeFiles(path));
    else if (CODE.test(entry.name)) out.push(path);
  }
  return out;
}

describe("MUTE1 contract: only reviewed writers touch the output mute", () => {
  const tree = ["scripts", "src", "flow-bar"].flatMap((d) => codeFiles(join(repo, d)))
    .map((f) => ({ path: relative(repo, f), text: readFileSync(f, "utf8") }))
    .filter((f) => f.path !== SELF);

  test("no unreviewed file in scripts/, src/ or flow-bar/ writes the output mute or volume", () => {
    expect(offenders(tree)).toEqual([]);
  });

  test("every reviewed writer still writes, and its restore test exists in this file", () => {
    expect(tree.filter((f) => writesMute(f.text)).map((f) => f.path).sort()).toEqual(Object.keys(REVIEWED_WRITERS).sort());
    const self = readFileSync(import.meta.path, "utf8");
    for (const anchor of Object.values(REVIEWED_WRITERS)) expect(self).toContain(anchor);
  });

  test("the UIE2E runner mutes only through the guard and never leaves output muted", () => {
    const script = readFileSync(join(repo, "scripts/voicebar-ui-e2e.sh"), "utf8");
    expect(writesMute(script)).toBe(false);
    expect(script).toContain('source "$repo/scripts/lib/output-mute-guard.sh"');
    expect(script).toContain("output_mute_guard_begin");
    expect(script).not.toMatch(/Leave output muted/i);
  });

  // Sol R1 bypasses: none of these restores, so each must fail the contract.
  const unsafe: [string, string][] = [
    ["mute-only-exit.sh", `osascript -e 'set volume output muted true'\ntrap 'osascript -e "set volume output muted true"' EXIT\n`],
    ["comment-finally.ts", "// finally\nBun.spawnSync(['osascript', '-e', 'set volume output muted true']);\n"],
    ["unrelated-finally.py", "try:\n    pass\nfinally:\n    print('done')\nsubprocess.run(['osascript', '-e', 'set volume output volume 0'])\n"],
    ["comment-finally.swift", '// finally\nlet p = Process(); p.arguments = ["-e", "set volume with output muted"]\n'],
    ["double-space.sh", "osascript -e 'set  volume output volume 0'\n"],
    ["case-and-tab.sh", "osascript -e 'SET\tVOLUME output muted TRUE'\n"],
    ["jxa.js", "Application.currentApplication().setVolume(0)\n"],
    ["guard-plus-direct.sh", 'source scripts/lib/output-mute-guard.sh\noutput_mute_guard_begin\nosascript -e "set volume without output muted"\n'],
  ];
  for (const [path, text] of unsafe) {
    test(`fails closed: ${path}`, () => expect(offenders([{ path, text }])).toEqual([path]));
  }

  const readOnly = [
    "osascript -e 'output muted of (get volume settings)'",
    "osascript -e 'output volume of (get volume settings)'",
    "[[ $(osascript -e 'output  muted of (get volume settings)') == true ]]",
    "let offset = volumeOffset // reset() volumes",
  ];
  for (const text of readOnly) {
    test(`read-only is allowed: ${text}`, () => expect(offenders([{ path: "probe.sh", text }])).toEqual([]));
  }
});

// A stateful osascript: reads print the stored state, writes store it, every call is logged.
// While `fail-unmute-once` exists, the next `set volume output muted false` fails and deletes it.
function osascriptStub(bin: string, dir: string, log: string) {
  writeFileSync(join(bin, "osascript"), `#!/bin/bash
printf '%s\\n' "$*" >> '${log}'
m='${dir}/muted' v='${dir}/volume'
case "$*" in
  *"set volume output muted false"*)
    if [[ -e '${dir}/fail-unmute-once' ]]; then rm '${dir}/fail-unmute-once'; exit 1; fi ;;
esac
case "$*" in
  *"return (output volume of s as string)"*) printf '%s:%s\\n' "$(cat $v)" "$(cat $m)"; exit 0 ;;
  *"output muted of (get volume settings)"*) cat $m; exit 0 ;;
esac
for arg; do
  case "$arg" in
    -e) ;;
    "set volume output muted true"|"set volume with output muted") echo true > $m ;;
    "set volume output muted false"|"set volume without output muted") echo false > $m ;;
    "set volume output volume "*) echo "\${arg##* }" > $v ;;
    *) echo "unexpected osascript: $*" >&2; exit 9 ;;
  esac
done
`, { mode: 0o700 });
}

function sandbox(prior: "true" | "false", volume = 35) {
  const dir = mkdtempSync(join(tmpdir(), "mute1-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const log = join(dir, "osascript.log");
  writeFileSync(join(dir, "muted"), `${prior}\n`);
  writeFileSync(join(dir, "volume"), `${volume}\n`);
  osascriptStub(bin, dir, log);
  const read = () => readFileSync(join(dir, "muted"), "utf8").trim();
  const readVolume = () => readFileSync(join(dir, "volume"), "utf8").trim();
  const calls = () => existsSync(log) ? readFileSync(log, "utf8") : "";
  const failUnmuteOnce = () => writeFileSync(join(dir, "fail-unmute-once"), "");
  return { dir, bin, read, readVolume, calls, failUnmuteOnce, path: `${bin}:/usr/bin:/bin` };
}

async function waitFor(path: string, ms = 10_000) {
  const until = Date.now() + ms;
  while (!existsSync(path)) {
    if (Date.now() > until) throw new Error(`timed out waiting for ${path}`);
    await Bun.sleep(25);
  }
}

describe("output-mute-guard.sh restores the state it found", () => {
  const guard = join(repo, "scripts/lib/output-mute-guard.sh");
  const driver = (dir: string, tail: string, begin = "output_mute_guard_begin || exit 1") => {
    const path = join(dir, "driver.sh");
    writeFileSync(path, `set -euo pipefail\nsource '${guard}'\n${begin}\n` +
      `output_mute_guard_confirm || exit 1\ntouch '${dir}/muted-during-run'\n${tail}\n`);
    return path;
  };
  const unmutes = (calls: string) => calls.split("\n").filter((l) => l === "-e set volume output muted false").length;

  for (const prior of ["false", "true"] as const) {
    for (const [name, tail, code] of [["exit 0", "exit 0", 0], ["exit 1", "false", 1]] as const) {
      test(`${name} with prior muted=${prior}`, () => {
        const s = sandbox(prior);
        try {
          const r = Bun.spawnSync(["/bin/bash", driver(s.dir, tail)], { env: { ...process.env, PATH: s.path } });
          expect(r.exitCode).toBe(code);
          expect(existsSync(join(s.dir, "muted-during-run"))).toBe(true);
          expect(s.calls()).toContain("set volume output muted true");
          expect(s.read()).toBe(prior);
        } finally { rmSync(s.dir, { recursive: true, force: true }); }
      }, SUBPROCESS_TEST_TIMEOUT_MS);
    }

    // Sol R1 defect 1: a second begin (or a re-source) must keep the first saved state.
    test(`begin twice and re-source keep prior muted=${prior}`, () => {
      const s = sandbox(prior);
      try {
        const twice = `output_mute_guard_begin || exit 1\nsource '${guard}'\noutput_mute_guard_begin || exit 1`;
        const r = Bun.spawnSync(["/bin/bash", driver(s.dir, "exit 0", twice)], { env: { ...process.env, PATH: s.path } });
        expect(r.exitCode).toBe(0);
        expect(s.read()).toBe(prior);
      } finally { rmSync(s.dir, { recursive: true, force: true }); }
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  for (const [signal, code] of [["SIGTERM", 143], ["SIGINT", 130]] as const) {
    test(`${signal} mid-run restores muted=false`, async () => {
      const s = sandbox("false");
      try {
        const child = Bun.spawn(["/bin/bash", driver(s.dir, "while :; do sleep 0.05; done")], { env: { ...process.env, PATH: s.path } });
        await waitFor(join(s.dir, "muted-during-run"));
        expect(s.read()).toBe("true");
        child.kill(signal);
        expect(await child.exited).toBe(code);
        expect(s.read()).toBe("false");
      } finally { rmSync(s.dir, { recursive: true, force: true }); }
    }, SUBPROCESS_TEST_TIMEOUT_MS);

    // Sol R1 defect 2: one failed unmute must not discard the saved state.
    test(`${signal} with one failed unmute still restores muted=false`, async () => {
      const s = sandbox("false");
      try {
        const child = Bun.spawn(["/bin/bash", driver(s.dir, "while :; do sleep 0.05; done")], { env: { ...process.env, PATH: s.path } });
        await waitFor(join(s.dir, "muted-during-run"));
        s.failUnmuteOnce();
        child.kill(signal);
        expect(await child.exited).toBe(code);
        expect(s.read()).toBe("false");
        expect(unmutes(s.calls())).toBe(2);
      } finally { rmSync(s.dir, { recursive: true, force: true }); }
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  test("EXIT with one failed unmute still restores muted=false", () => {
    const s = sandbox("false");
    try {
      const r = Bun.spawnSync(["/bin/bash", driver(s.dir, `touch '${s.dir}/fail-unmute-once'\nexit 0`)], { env: { ...process.env, PATH: s.path } });
      expect(r.exitCode).toBe(0);
      expect(s.read()).toBe("false");
      expect(unmutes(s.calls())).toBe(2);
    } finally { rmSync(s.dir, { recursive: true, force: true }); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("explicit restore reports a failure, keeps the state, and a later restore succeeds", () => {
    const s = sandbox("false");
    try {
      const tail = `touch '${s.dir}/fail-unmute-once'
if output_mute_guard_restore; then exit 7; fi
[[ $output_mute_guard_prior == false ]] || exit 8
output_mute_guard_restore || exit 9
[[ -z $output_mute_guard_prior ]] || exit 10
output_mute_guard_restore || exit 11
exit 0`;
      const r = Bun.spawnSync(["/bin/bash", driver(s.dir, tail)], { env: { ...process.env, PATH: s.path } });
      expect(r.exitCode).toBe(0);
      expect(s.read()).toBe("false");
      expect(unmutes(s.calls())).toBe(2);
    } finally { rmSync(s.dir, { recursive: true, force: true }); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("an unreadable prior state refuses to mute at all", () => {
    const s = sandbox("false");
    try {
      writeFileSync(join(s.dir, "muted"), "missing value\n");
      const r = Bun.spawnSync(["/bin/bash", driver(s.dir, "exit 0")], { env: { ...process.env, PATH: s.path } });
      expect(r.exitCode).toBe(1);
      expect(s.calls()).not.toContain("set volume");
    } finally { rmSync(s.dir, { recursive: true, force: true }); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

// The reviewed second writer: its own cleanup EXIT trap, driven in source-only mode.
describe("auto-f5-verify.sh restores the volume and mute it found", () => {
  const script = join(repo, "scripts/auto-f5-verify.sh");
  const driver = (dir: string, tail: string) => {
    const path = join(dir, "driver.sh");
    writeFileSync(path, `set -euo pipefail\nVOICELAYER_AUTO_F5_SOURCE_ONLY=1 source '${script}'\ntrap cleanup EXIT\n` +
      `capture_system_volume\nset_system_volume_for_capture\ntouch '${dir}/capturing'\n${tail}\n`);
    return path;
  };
  const f5Env = (s: { dir: string; path: string }) => ({ PATH: s.path,
    VOICELAYER_AUTO_F5_WORK_DIR: s.dir, VOICELAYER_AUTO_F5_LOG_FILE: join(s.dir, "auto-f5.log") });

  for (const prior of ["false", "true"] as const) {
    for (const [name, tail, code] of [["exit 0", "exit 0", 0], ["die", "die boom", 1]] as const) {
      test(`${name} with prior muted=${prior}`, () => {
        const s = sandbox(prior, 35);
        try {
          const r = Bun.spawnSync(["/bin/bash", driver(s.dir, tail)], { env: { ...process.env, ...f5Env(s) } });
          expect(r.exitCode).toBe(code);
          expect(s.calls()).toContain("set volume without output muted");
          expect(s.read()).toBe(prior);
          expect(s.readVolume()).toBe("35");
        } finally { rmSync(s.dir, { recursive: true, force: true }); }
      }, SUBPROCESS_TEST_TIMEOUT_MS);
    }
  }

  test("SIGTERM mid-capture restores muted=true and the volume", async () => {
    const s = sandbox("true", 35);
    try {
      const child = Bun.spawn(["/bin/bash", driver(s.dir, "while :; do sleep 0.05; done")], { env: { ...process.env, ...f5Env(s) } });
      await waitFor(join(s.dir, "capturing"));
      expect(s.read()).toBe("false");
      child.kill("SIGTERM");
      await child.exited;
      expect(s.read()).toBe("true");
      expect(s.readVolume()).toBe("35");
    } finally { rmSync(s.dir, { recursive: true, force: true }); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

// The real runner, copied into a fake repo whose build/test tools are stubs.
describe("voicebar-ui-e2e.sh restores the mute it found", () => {
  const supervisorExits = [0, 1, 2, 3] as const;
  const supervisorVerdicts = {
    0: "verdict=PASS exit=0 mute=restored",
    1: "verdict=FAIL exit=1 mute=retained",
    2: "verdict=PREFLIGHT_REFUSED exit=2 mute=restored",
    3: "verdict=PASS exit=3 mute=retained-by-design",
  };

  function fakeRepo(prior: "true" | "false", build: string,
    supervisorExit: (typeof supervisorExits)[number] = 0) {
    const s = sandbox(prior);
    const root = join(s.dir, "repo");
    for (const d of ["scripts/lib", "flow-bar"]) mkdirSync(join(root, d), { recursive: true });
    for (const f of ["scripts/voicebar-ui-e2e.sh", "scripts/lib/output-mute-guard.sh", "scripts/lib/noindex-path.sh"]) {
      writeFileSync(join(root, f), readFileSync(join(repo, f), "utf8"));
    }
    writeFileSync(join(root, "flow-bar/build-app.sh"), build);
    for (const tool of ["xcodebuild", "xcrun", "swift", "bun"]) {
      writeFileSync(join(s.bin, tool), "#!/bin/bash\nexit 0\n", { mode: 0o700 });
    }
    // Only the supervisor fixture produces a verdict; unrelated Python steps stay silent.
    // Its mute field is the inner supervisor state, before the shell's EXIT restoration.
    const supervisorLine = `${supervisorVerdicts[supervisorExit]} receipt=${join(s.dir, "out.noindex/operator-state.json")}`;
    const pythonLog = join(s.dir, "python-calls");
    writeFileSync(join(s.bin, "python3"), `#!/bin/bash
printf '%s\\n' "$*" >> '${pythonLog}'
case "$1" in
  */voicebar-ui-e2e-supervisor.py)
    printf '%s\\n' '${supervisorLine}'
    exit ${supervisorExit} ;;
  */voicebar-ui-e2e-run.py) exit 91 ;;
esac
exit 0
`, { mode: 0o700 });
    const cmd = ["/bin/bash", join(root, "scripts/voicebar-ui-e2e.sh"), "--output", join(s.dir, "out.noindex")];
    const cleanup = () => {
      const pathFile = join(s.dir, "out.noindex/sandbox-path.txt");
      if (existsSync(pathFile)) {
        const box = readFileSync(pathFile, "utf8").trim();
        if (/^\/tmp\/vl-ui-/.test(box) && existsSync(join(box, ".uie2e-sandbox"))) rmSync(box, { recursive: true, force: true });
      }
      rmSync(s.dir, { recursive: true, force: true });
    };
    return { ...s, root, cmd, cleanup, supervisorLine, pythonLog };
  }

  // Ad-hoc signing a copied binary needs the real macOS codesign.
  for (const prior of ["false", "true"] as const) {
    for (const supervisorExit of supervisorExits) {
      test.skipIf(process.platform !== "darwin")(`exit ${supervisorExit} restores muted=${prior}`, () => {
        const build = `#!/bin/bash
for a; do [[ $prev == --install-path ]] && app=$a; prev=$a; done
mkdir -p "$app/Contents/MacOS" && cp /usr/bin/true "$app/Contents/MacOS/VoiceBar"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string VoiceBar "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.voicelayer.voicebar.uie2e "$app/Contents/Info.plist"
`;
        const r0 = fakeRepo(prior, build, supervisorExit);
        try {
          const r = Bun.spawnSync(r0.cmd, { env: { ...process.env, PATH: r0.path } });
          expect(r.stdout.toString().split("\n")).toContain(r0.supervisorLine);
          expect(r.stdout.toString()).not.toContain("PASS UIE2E");
          const supervisorCalls = readFileSync(r0.pythonLog, "utf8").trim().split("\n")
            .filter((line) => line.startsWith(join(r0.root, "scripts/voicebar-ui-e2e-supervisor.py")));
          expect(supervisorCalls).toEqual([
            `${join(r0.root, "scripts/voicebar-ui-e2e-supervisor.py")} ${join(r0.dir, "out.noindex")} --scenario full`,
          ]);
          expect(r.exitCode).toBe(supervisorExit);
          expect(r0.calls()).toContain("set volume output muted true");
          expect(r.stderr.toString()).toContain(`output mute restored to ${prior}`);
          expect(r0.read()).toBe(prior);
        } finally { r0.cleanup(); }
      }, SUBPROCESS_TEST_TIMEOUT_MS);
    }
  }

  test("exit 1 (build fails) restores muted=false", () => {
    const r0 = fakeRepo("false", "#!/bin/bash\nexit 1\n");
    try {
      const r = Bun.spawnSync(r0.cmd, { env: { ...process.env, PATH: r0.path } });
      expect(r.exitCode).toBe(1);
      expect(r0.calls()).toContain("set volume output muted true");
      expect(r0.read()).toBe("false");
    } finally { r0.cleanup(); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("SIGTERM during the build restores muted=false", async () => {
    const r0 = fakeRepo("false", "");
    try {
      writeFileSync(join(r0.root, "flow-bar/build-app.sh"),
        `#!/bin/bash\necho $$ > '${r0.dir}/building'\nwhile :; do sleep 0.05; done\n`);
      const child = Bun.spawn(r0.cmd, { env: { ...process.env, PATH: r0.path } });
      await waitFor(join(r0.dir, "building"));
      expect(r0.read()).toBe("true");
      // A T3 restart signals the whole process group: the runner and its foreground build.
      child.kill("SIGTERM");
      process.kill(Number(readFileSync(join(r0.dir, "building"), "utf8")), "SIGTERM");
      expect(await child.exited).toBe(143);
      expect(r0.read()).toBe("false");
    } finally { r0.cleanup(); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("--build-only never touches the mute", () => {
    const r0 = fakeRepo("false", "#!/bin/bash\nexit 1\n");
    try {
      const r = Bun.spawnSync([...r0.cmd, "--build-only"], { env: { ...process.env, PATH: r0.path } });
      expect(r.exitCode).toBe(1);
      expect(r0.calls()).toBe("");
    } finally { r0.cleanup(); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});
