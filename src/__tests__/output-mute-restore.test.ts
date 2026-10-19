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
// Any write of the output mute or volume. Read-only queries such as
// `output muted of (get volume settings)` match none of these.
const MUTE_WRITE = /set volume|output muted true|with output muted/;

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

function shellFunctionBody(source: string, name: string): string | undefined {
  const start = source.search(new RegExp(`^\\s*(?:function\\s+)?${name}\\s*\\(\\)\\s*\\{`, "m"));
  if (start < 0) return undefined;
  const end = source.indexOf("\n}", start);
  return source.slice(start, end < 0 ? undefined : end);
}

// True when the EXIT trap (directly or through up to three function calls) writes the mute back.
function shellExitTrapRestores(source: string): boolean {
  const traps = [...source.matchAll(/^\s*trap\s+('[^']*'|"[^"]*"|\S+)\s+([A-Z ]+)$/gm)]
    .filter((m) => m[2].split(/\s+/).includes("EXIT"));
  const restores = (code: string, depth: number): boolean => {
    if (MUTE_WRITE.test(code) || /set volume output muted \$/.test(code)) return true;
    if (depth === 0) return false;
    for (const call of code.match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []) {
      const body = shellFunctionBody(source, call);
      if (body && body !== code && restores(body, depth - 1)) return true;
    }
    return false;
  };
  return traps.some((m) => restores(m[1].replace(/^['"]|['"]$/g, ""), 3));
}

describe("MUTE1 contract: every output-mute writer restores what it found", () => {
  const files = ["scripts", "src", "flow-bar"].flatMap((d) => codeFiles(join(repo, d)))
    .filter((f) => relative(repo, f) !== SELF);
  const writers = files.filter((f) => readFileSync(f, "utf8").split("\n").some((l) => MUTE_WRITE.test(l)));

  test("the scan sees the known writers", () => {
    const names = writers.map((f) => relative(repo, f)).sort();
    expect(names).toContain("scripts/auto-f5-verify.sh");
    expect(names).toContain("scripts/lib/output-mute-guard.sh");
  });

  test("each writer restores from an EXIT trap or a finally", () => {
    const offenders = writers.filter((f) => {
      const source = readFileSync(f, "utf8");
      return /\.(sh|bash|zsh)$/.test(f) ? !shellExitTrapRestores(source) : !/\bfinally\b/.test(source);
    }).map((f) => relative(repo, f));
    expect(offenders).toEqual([]);
  });

  test("the UIE2E runner mutes only through the guard and never leaves output muted", () => {
    const script = readFileSync(join(repo, "scripts/voicebar-ui-e2e.sh"), "utf8");
    expect(script.split("\n").filter((l) => MUTE_WRITE.test(l))).toEqual([]);
    expect(script).toContain('source "$repo/scripts/lib/output-mute-guard.sh"');
    expect(script).toContain("output_mute_guard_begin");
    expect(script).not.toMatch(/Leave output muted/i);
  });

  test("read-only queries are not writes", () => {
    expect(MUTE_WRITE.test("osascript -e 'output muted of (get volume settings)'")).toBe(false);
  });
});

// A stateful osascript: reads print the stored mute state, writes store it, every call is logged.
function osascriptStub(bin: string, state: string, log: string) {
  writeFileSync(join(bin, "osascript"), `#!/bin/bash
printf '%s\\n' "$*" >> '${log}'
case "$*" in
  *"output muted of (get volume settings)"*) cat '${state}' ;;
  *"set volume output muted true"*) echo true > '${state}' ;;
  *"set volume output muted false"*) echo false > '${state}' ;;
  *) echo "unexpected osascript: $*" >&2; exit 9 ;;
esac
`, { mode: 0o700 });
}

function sandbox(prior: "true" | "false") {
  const dir = mkdtempSync(join(tmpdir(), "mute1-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const state = join(dir, "muted"), log = join(dir, "osascript.log");
  writeFileSync(state, `${prior}\n`);
  osascriptStub(bin, state, log);
  const read = () => readFileSync(state, "utf8").trim();
  const calls = () => existsSync(log) ? readFileSync(log, "utf8") : "";
  return { dir, bin, read, calls, path: `${bin}:/usr/bin:/bin` };
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
  const driver = (dir: string, tail: string) => {
    const path = join(dir, "driver.sh");
    writeFileSync(path, `set -euo pipefail\nsource '${guard}'\noutput_mute_guard_begin || exit 1\n` +
      `output_mute_guard_confirm || exit 1\ntouch '${dir}/muted-during-run'\n${tail}\n`);
    return path;
  };

  for (const prior of ["false", "true"] as const) {
    for (const [name, tail, code] of [["exit 0", "exit 0", 0], ["exit 1", "false", 1]] as const) {
      test(`${name} with prior muted=${prior}`, () => {
        const s = sandbox(prior);
        try {
          const r = Bun.spawnSync(["/bin/bash", driver(s.dir, tail)], { env: { ...process.env, PATH: s.path } });
          expect(r.exitCode).toBe(code);
          expect(existsSync(join(s.dir, "muted-during-run"))).toBe(true);
          expect(s.calls()).toContain("set volume output muted true");
          expect(s.calls().trim().split("\n").at(-1)).toBe(`-e set volume output muted ${prior}`);
          expect(s.read()).toBe(prior);
        } finally { rmSync(s.dir, { recursive: true, force: true }); }
      }, SUBPROCESS_TEST_TIMEOUT_MS);
    }
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
  }

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

// The real runner, copied into a fake repo whose build/test tools are stubs.
describe("voicebar-ui-e2e.sh restores the mute it found", () => {
  function fakeRepo(prior: "true" | "false", build: string) {
    const s = sandbox(prior);
    const root = join(s.dir, "repo");
    for (const d of ["scripts/lib", "flow-bar"]) mkdirSync(join(root, d), { recursive: true });
    for (const f of ["scripts/voicebar-ui-e2e.sh", "scripts/lib/output-mute-guard.sh"]) {
      writeFileSync(join(root, f), readFileSync(join(repo, f), "utf8"));
    }
    writeFileSync(join(root, "flow-bar/build-app.sh"), build);
    for (const tool of ["python3", "xcodebuild", "xcrun", "swift", "bun"]) {
      writeFileSync(join(s.bin, tool), "#!/bin/bash\nexit 0\n", { mode: 0o700 });
    }
    const cmd = ["/bin/bash", join(root, "scripts/voicebar-ui-e2e.sh"), "--output", join(s.dir, "out")];
    const cleanup = () => {
      const pathFile = join(s.dir, "out/sandbox-path.txt");
      if (existsSync(pathFile)) {
        const box = readFileSync(pathFile, "utf8").trim();
        if (/^\/tmp\/vl-ui-/.test(box) && existsSync(join(box, ".uie2e-sandbox"))) rmSync(box, { recursive: true, force: true });
      }
      rmSync(s.dir, { recursive: true, force: true });
    };
    return { ...s, root, cmd, cleanup };
  }

  // Ad-hoc signing a copied binary needs the real macOS codesign.
  test.skipIf(process.platform !== "darwin")("exit 0 restores muted=false", () => {
    const build = `#!/bin/bash
for a; do [[ $prev == --install-path ]] && app=$a; prev=$a; done
mkdir -p "$app/Contents/MacOS" && cp /usr/bin/true "$app/Contents/MacOS/VoiceBar"
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string VoiceBar "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.voicelayer.voicebar.uie2e "$app/Contents/Info.plist"
`;
    const r0 = fakeRepo("false", build);
    try {
      const r = Bun.spawnSync(r0.cmd, { env: { ...process.env, PATH: r0.path } });
      expect(r.stdout.toString()).toContain("PASS UIE2E");
      expect(r.exitCode).toBe(0);
      expect(r0.calls()).toContain("set volume output muted true");
      expect(r0.read()).toBe("false");
    } finally { r0.cleanup(); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
