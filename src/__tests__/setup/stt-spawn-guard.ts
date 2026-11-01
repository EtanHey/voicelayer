import { existsSync, lstatSync, mkdirSync, realpathSync, readFileSync, writeFileSync } from "node:fs";
import { basename, delimiter, isAbsolute, join, resolve, sep } from "node:path";

const STT_TOOLS = ["whisper-cli", "whisper-cpp", "whisper-server"] as const;
const stubSource = (tool: string, executable: string, denied: string) =>
  `#!${executable}\nprocess.env.VOICELAYER_TEST_STT_ENGINE = ${JSON.stringify(tool)};\nawait import(${JSON.stringify(denied)});\n`;

function isGuardStubDirectory(dir: string): boolean {
  if (basename(dir) !== "stt-disabled-bin") return false;
  try {
    const first = join(dir, STT_TOOLS[0]);
    if (lstatSync(first).size > 16_384) return false;
    const match = /^#!([^\n]+)\nprocess\.env\.VOICELAYER_TEST_STT_ENGINE = "whisper-cli";\nawait import\((.+)\);\n$/.exec(readFileSync(first, "utf8"));
    if (!match || !isAbsolute(match[1]!) || realpathSync(match[1]!) !== realpathSync(process.execPath)) return false;
    const denied: unknown = JSON.parse(match[2]!);
    if (typeof denied !== "string" || !isAbsolute(denied) || lstatSync(denied).size > 16_384 ||
        !readFileSync(denied).equals(readFileSync(join(import.meta.dir, "stt-denied.ts")))) return false;
    return STT_TOOLS.every(tool => {
      const path = join(dir, tool), stat = lstatSync(path);
      return stat.isFile() && !stat.isSymbolicLink() && stat.size <= 16_384 &&
        readFileSync(path, "utf8") === stubSource(tool, match[1]!, denied);
    });
  } catch { return false; }
}

/** Non-darwin policy; inherited denial scripts are not installed engines. */
export function assertNoInstalledStt(dirs: string[], roots: string[]): void {
  for (const dir of dirs) {
    if (isGuardStubDirectory(dir)) continue;
    if (STT_TOOLS.some(tool => {
      const path = join(dir, tool);
      if (!existsSync(path)) return false;
      try { const actual = realpathSync(path); return !roots.some(root => actual.startsWith(root + sep)); }
      catch { return true; }
    })) throw new Error("STT guard requires descendant enforcement on a host with installed Whisper; live tests need explicit opt-in");
  }
}

export function trustedParentRunRoot(parentRoot?: string): string | undefined {
  try {
    if (parentRoot && /^\d+-[a-f0-9]{4,6}$/.test(basename(parentRoot)) &&
        basename(resolve(parentRoot, "..")) === ".test-tmp" &&
        lstatSync(parentRoot).isDirectory() && !lstatSync(parentRoot).isSymbolicLink() &&
        realpathSync(parentRoot) === resolve(parentRoot)) return resolve(parentRoot);
  } catch { /* No inherited trust on missing or malformed roots. */ }
  return undefined;
}

/** Fail closed for native STT, including installed absolute paths. Fake engines
 * physically inside an isolated test root remain usable by protocol tests. */
export function installSttSpawnGuard(runRoot: string, parentRoot?: string) {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return null;
  const tools = new Set<string>(STT_TOOLS);
  const bin = join(runRoot, "stt-disabled-bin"); mkdirSync(bin, { mode: 0o700 });
  const denied = join(import.meta.dir, "stt-denied.ts");
  const inheritedLog = process.env.VOICELAYER_TEST_STT_STUB_LOG;
  const within = (path: string, root: string) => path.startsWith(root + sep);
  // An inherited /opt/homebrew (or symlink) is never a fake-fixture root.
  const trustedParent = trustedParentRunRoot(parentRoot);
  let log = join(runRoot, "stt-spawn-attempts.jsonl");
  if (inheritedLog && trustedParent && resolve(inheritedLog) === join(trustedParent, "stt-spawn-attempts.jsonl")) {
    try { if (!lstatSync(inheritedLog).isSymbolicLink()) log = inheritedLog; }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") log = inheritedLog; }
  }
  // A shell intermediary can expose argv but no env through KERN_PROCARGS2.
  // Keep hook cleanup identity visible from the first executable onward.
  for (const tool of tools) writeFileSync(join(bin, tool),
    stubSource(tool, process.execPath, denied), { mode: 0o700 });
  process.env.PATH = bin + delimiter + (process.env.PATH ?? "");
  process.env.QA_VOICE_WHISPER_MODEL = join(runRoot, "NO-LIVE-WHISPER-MODEL.bin");
  process.env.VOICELAYER_TEST_STT_STUB_LOG = log;
  const roots = [realpathSync(resolve(runRoot, "..")), ...(trustedParent ? [trustedParent] : [])];
  if (process.platform === "darwin") {
    // Apply to THIS test process, not just the public Bun APIs. The kernel
    // inherits it into shell/Bun-e/Node descendants and cannot be bypassed by
    // changing PATH or restoring a mocked spawn. No native engine is probed.
    // A fresh tree proves enforcement once. Descendants inherit the kernel
    // policy; a cached root avoids repeating the successful shell execution.
    // The cache is only a hint: a real EPERM on its unchanged canary is still
    // required, so a forged environment/marker cannot turn off enforcement.
    const canaryName = "voicelayer-test-stt-kernel-canary";
    const canaryBody = "#!/bin/sh\nexit 77\n";
    const cacheName = "stt-kernel-verified.json";
    const inheritedCacheRoot = trustedParentRunRoot(process.env.VOICELAYER_TEST_STT_GUARD_ROOT);
    delete process.env.VOICELAYER_TEST_STT_GUARD_ROOT;
    const probeTimeoutMs = 10_000;
    const probe = (path: string) => {
      try {
        const x = Bun.spawnSync([path], { env: process.env, stdin: "ignore", stdout: "ignore", stderr: "ignore", timeout: probeTimeoutMs });
        return { status: x.exitCode, signal: x.signalCode ?? null, error: null };
      } catch (error) {
        return { status: null, signal: null,
          error: { code: (error as NodeJS.ErrnoException).code, message: String(error) } };
      }
    };
    const succeeded = (result: ReturnType<typeof probe>) => result.status === 77 && result.error === null;
    const deniedProbe = (result: ReturnType<typeof probe>) => result.error?.code === "EPERM";
    let cached = false;
    if (trustedParent && inheritedCacheRoot) {
      try {
        const marker = join(inheritedCacheRoot, cacheName);
        const canary = join(inheritedCacheRoot, canaryName);
        const stat = lstatSync(marker);
        const state = stat.isFile() && !stat.isSymbolicLink() && stat.size <= 4096
          ? JSON.parse(readFileSync(marker, "utf8")) : null;
        const canaryStat = lstatSync(canary);
        if (state?.policy === "native-stt-deny-canonical-v1" &&
            Array.isArray(state.roots) && state.roots.every((root: unknown) =>
              typeof root === "string" && realpathSync(root) === root) &&
            state.roots.some((root: string) => within(realpathSync(runRoot), root)) &&
            canaryStat.isFile() && !canaryStat.isSymbolicLink() &&
            readFileSync(canary, "utf8") === canaryBody && deniedProbe(probe(canary))) {
          cached = true;
          process.env.VOICELAYER_TEST_STT_GUARD_ROOT = inheritedCacheRoot;
        }
      } catch { /* A missing, changed or unverified cache uses the full check. */ }
    }
    if (!cached) {
      const canary = join(runRoot, canaryName);
      const neutral = join(runRoot, "stt-neutral-exec-probe");
      for (const path of [canary, neutral]) writeFileSync(path, canaryBody, { mode: 0o700, flag: "wx" });
      const neutralResult = probe(neutral), canaryResult = probe(canary);
      const inherited = deniedProbe(canaryResult) && succeeded(neutralResult);
      if (!inherited) {
        if (!succeeded(neutralResult)) throw new Error("Cannot establish STT guard: harmless fixture execution unavailable " +
          JSON.stringify({ timeoutMs: probeTimeoutMs, neutral: neutralResult, canary: canaryResult }));
        const { dlopen, ptr, CString } = require("bun:ffi") as typeof import("bun:ffi");
        const library = dlopen("/usr/lib/libsandbox.1.dylib", {
          sandbox_init: { args: ["ptr", "u64", "ptr"], returns: "i32" },
          sandbox_free_error: { args: ["ptr"], returns: "void" },
        });
        // Descendants inherit these canonical fixture ancestors. A directory that
        // merely looks like another checkout's .test-tmp is never execution authority.
        // macOS ps is setuid; permit this immutable read-only leaf outside the sandbox.
        const outsideFixtureRoots = roots.map(root => `(require-not (subpath ${JSON.stringify(root)}))`).join(" ");
        const profile = Buffer.from(`(version 1)(allow default)(allow process-exec (literal "/bin/ps") (with no-sandbox))(deny process-exec (regex #"/voicelayer-test-stt-kernel-canary$"))(deny process-exec (require-all (regex #"(^|/)(whisper-cli|whisper-cpp|whisper-server)$") ${outsideFixtureRoots}))` + String.fromCharCode(0));
        const error = new BigUint64Array(1);
        if (library.symbols.sandbox_init(ptr(profile), 0, ptr(error)) !== 0) {
          const message = error[0] ? new CString(Number(error[0])).toString() : "unknown";
          if (error[0]) library.symbols.sandbox_free_error(Number(error[0]));
          throw new Error(`STT guard kernel policy failed: ${message}`);
        }
        library.close();
        const enforcedCanary = probe(canary), enforcedNeutral = probe(neutral);
        if (!deniedProbe(enforcedCanary) || !succeeded(enforcedNeutral))
          throw new Error("STT guard kernel enforcement check failed " +
            JSON.stringify({ timeoutMs: probeTimeoutMs, canary: enforcedCanary, neutral: enforcedNeutral }));
        writeFileSync(join(runRoot, cacheName), JSON.stringify({ policy: "native-stt-deny-canonical-v1", roots }),
          { mode: 0o400, flag: "wx" });
        process.env.VOICELAYER_TEST_STT_GUARD_ROOT = runRoot;
      }
    }
  } else {
    // This host cannot install the macOS descendant policy. Do not run an
    // unopted suite against an installed engine with only PATH interception.
    const dirs = [...(process.env.PATH ?? "").split(delimiter), "/usr/local/bin", "/usr/bin", "/opt/homebrew/bin"];
    assertNoInstalledStt(dirs, roots);
  }
  const fake = (path: string) => {
    try { const actual = realpathSync(path); return roots.some((root) => within(actual, root)) && !within(actual, bin); }
    catch { return false; }
  };
  return (cmd: unknown, env: NodeJS.ProcessEnv) => {
    env.PATH = bin + delimiter + (env.PATH ?? process.env.PATH ?? "");
    env.VOICELAYER_TEST_STT_STUB_LOG = log;
    env.VOICELAYER_TEST_STT_CALLSITE = new Error().stack?.split("\n").filter((line) => !/stt-spawn-guard|setup\/preload/.test(line)).join("\n");
    if (!Array.isArray(cmd) || typeof cmd[0] !== "string" || !tools.has(basename(cmd[0]))) return cmd;
    let executable = cmd[0];
    if (!executable.includes(sep)) {
      const found = (env.PATH ?? "").split(delimiter).map((dir) => join(dir, executable))
        .find((path) => !path.startsWith(bin + sep) && existsSync(path));
      if (found && fake(found)) executable = found;
    }
    if (fake(resolve(executable))) return [executable, ...cmd.slice(1)];
    env.VOICELAYER_TEST_STT_ENGINE = basename(executable);
    return [process.execPath, denied, basename(executable), ...cmd.slice(1)];
  };
}
