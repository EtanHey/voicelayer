import { existsSync, statSync, lstatSync, mkdirSync, realpathSync, readFileSync, writeFileSync, readdirSync, openSync, closeSync } from "node:fs";
import { basename, delimiter, isAbsolute, join, resolve, sep } from "node:path";

// Capture before preload replaces the public Bun API. Node child_process can
// delegate to that API too, so it cannot establish raw kernel refusal here.
const kernelSpawnSync = Bun.spawnSync.bind(Bun);

import { pythonScriptOperand, isRealParakeetWorker, canonicalRuntime, canonicalWeightTargets } from "./stt-parakeet-policy";

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
      try {
        const stat = statSync(path);
        if (!stat.isFile() || (stat.mode & 0o111) === 0) return false;
        const actual = realpathSync(path);
        return !roots.some(root => actual.startsWith(root + sep));
      }
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
  const originalDirs = (process.env.PATH ?? "").split(delimiter).filter(dir => !isGuardStubDirectory(dir) && basename(dir) !== "stt-disabled-python-bin");
  const pythons = new Map<string, string>();
  for (const dir of originalDirs) {
    try { for (const name of readdirSync(dir)) {
      if (!/^(python(?:\d+(?:\.\d+)*)?|Python)$/.test(name) || pythons.has(name)) continue;
      const path = join(dir, name), stat = statSync(path);
      if (stat.isFile() && (stat.mode & 0o111)) pythons.set(name, path);
    } } catch { /* Missing PATH entries are not runtimes. */ }
  }
  const bin = join(runRoot, "stt-disabled-bin"); mkdirSync(bin, { mode: 0o700 });
  const pythonBin = join(runRoot, "stt-disabled-python-bin"); mkdirSync(pythonBin, { mode: 0o700 });
  const pythonMap = (path: string) => {
    const found: Record<string, string> = {};
    for (const name of pythons.keys()) {
      for (const dir of path.split(delimiter)) {
        if (["stt-disabled-bin", "stt-disabled-python-bin"].includes(basename(dir))) continue;
        const candidate = join(dir, name);
        try {
          const stat = statSync(candidate);
          if (!stat.isFile() || !(stat.mode & 0o111)) continue;
          const actual = realpathSync(candidate);
          // A fixture can symlink our transparent dispatcher into a minimal PATH.
          found[name] = basename(resolve(actual, "..")) === "stt-disabled-python-bin"
            ? pythons.get(name)! : candidate;
          break;
        } catch { /* Missing PATH entries are not executable authority. */ }
      }
    }
    return found;
  };
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
  process.env.VOICELAYER_TEST_STT_PYTHON_MAP = JSON.stringify(Object.fromEntries(pythons));
  process.env.PATH = bin + delimiter + pythonBin + delimiter + (process.env.PATH ?? "");
  process.env.QA_VOICE_WHISPER_MODEL = join(runRoot, "NO-LIVE-WHISPER-MODEL.bin");
  process.env.VOICELAYER_TEST_STT_STUB_LOG = log;
  const roots = [realpathSync(resolve(runRoot, "..")), ...(trustedParent ? [trustedParent] : [])];
  process.env.VOICELAYER_TEST_STT_FIXTURE_ROOTS = JSON.stringify(roots);
  const runtime = canonicalRuntime(process.env.VOICELAYER_PARAKEET_PYTHON);
  const protectedRuntimes = runtime && !roots.some(root => within(runtime, root)) ? [runtime] : [];
  const weights = canonicalWeightTargets(process.env, roots);
  for (const [name, path] of pythons) writeFileSync(join(pythonBin, name),
    `#!${process.execPath}\nprocess.argv = [process.argv[0], process.argv[1], ${JSON.stringify(path)}, ...process.argv.slice(2)];\nawait import(${JSON.stringify(join(import.meta.dir, "stt-python.ts"))});\n`, { mode: 0o700 });
  if (process.platform === "darwin") {
    // Apply to THIS test process, not just the public Bun APIs. The kernel
    // inherits it into shell/Bun-e/Node descendants and cannot be bypassed by
    // changing PATH or restoring a mocked spawn. No native engine is probed.
    // A fresh tree proves enforcement once. Descendants inherit the kernel
    // policy; a cached root avoids repeating the successful shell execution.
    // The cache is only a hint: a real EPERM on its unchanged canary is still
    // required, so a forged environment/marker cannot turn off enforcement.
    const canaryName = "voicelayer-test-stt-kernel-canary-v3";
    const weightName = "voicelayer-test-stt-weight-canary";
    const policy = "native-stt-parakeet-weights-v3";
    const weightDenied = (path: string) => {
      try { readFileSync(path); return false; } catch (error) { return ["EPERM", "EACCES"].includes((error as NodeJS.ErrnoException).code ?? ""); }
    };
    // Cache metadata is never enforcement. Opening without reading any bytes
    // proves each immutable target is kernel-denied, even if a marker is forged.
    const deniedOpen = (path: string) => {
      try { const fd = openSync(path, "r"); closeSync(fd); return false; }
      catch (error) { return ["EPERM", "EACCES"].includes((error as NodeJS.ErrnoException).code ?? ""); }
    };
    const canaryBody = "#!/bin/sh\nexit 77\n";
    const cacheName = "stt-kernel-verified.json";
    const inheritedCacheRoot = trustedParentRunRoot(process.env.VOICELAYER_TEST_STT_GUARD_ROOT);
    delete process.env.VOICELAYER_TEST_STT_GUARD_ROOT;
    const probeTimeoutMs = 10_000;
    const probe = (path: string, args: string[] = []) => {
      try {
        const x = Bun.spawnSync([path, ...args], { env: process.env, stdin: "ignore", stdout: "ignore", stderr: "ignore", timeout: probeTimeoutMs });
        return { status: x.exitCode, signal: x.signalCode ?? null, error: null };
      } catch (error) {
        return { status: null, signal: null,
          error: { code: (error as NodeJS.ErrnoException).code, message: String(error) } };
      }
    };
    // The preload wrapper would turn a protected interpreter into exit78.
    // Use the captured unwrapped primitive to require the actual kernel EPERM.
    const runtimeDenied = (path: string) => {
      try { kernelSpawnSync([path, "--version"], { env: process.env,
        stdin: "ignore", stdout: "ignore", stderr: "ignore", timeout: probeTimeoutMs }); return false; }
      catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
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
        if (state?.policy === policy &&
            Array.isArray(state.weights) && weights.every(path => state.weights.includes(path)) &&
            Array.isArray(state.runtimes) && state.runtimes.every((path: unknown) => typeof path === "string" && canonicalRuntime(path) === path) &&
            protectedRuntimes.every(path => state.runtimes.includes(path)) &&
            weightDenied(join(inheritedCacheRoot, weightName)) &&
            Array.isArray(state.roots) && state.roots.every((root: unknown) =>
              typeof root === "string" && realpathSync(root) === root) &&
            state.roots.some((root: string) => within(realpathSync(runRoot), root)) &&
            canaryStat.isFile() && !canaryStat.isSymbolicLink() &&
            readFileSync(canary, "utf8") === canaryBody && deniedProbe(probe(canary)) &&
            state.runtimes.every(runtimeDenied) && weights.every(deniedOpen)) {
          cached = true;
          process.env.VOICELAYER_TEST_STT_GUARD_ROOT = inheritedCacheRoot;
        }
      } catch { /* A missing, changed or unverified cache uses the full check. */ }
    }
    if (!cached) {
      const canary = join(runRoot, canaryName);
      const neutral = join(runRoot, "stt-neutral-exec-probe");
      const weight = join(runRoot, weightName);
      writeFileSync(weight, "SYNTHETIC_ONLY", {mode: 0o600, flag: "wx"});
      for (const path of [canary, neutral]) writeFileSync(path, canaryBody, { mode: 0o700, flag: "wx" });
      const neutralResult = probe(neutral), canaryResult = probe(canary);
      // An outside copied checkout can inherit a stronger policy without being
      // entitled to new fixture exceptions. Prove each requested protection;
      // do not try to reinitialize Seatbelt or trust a missing/stale cache.
      const inherited = deniedProbe(canaryResult) && succeeded(neutralResult) && weightDenied(weight) &&
        protectedRuntimes.every(runtimeDenied) && weights.every(deniedOpen);
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
        const weightRules = weights.map(path => `(deny file-read-data (literal ${JSON.stringify(path)}))`).join("");
        const runtimeRules = protectedRuntimes.map(path => `(deny process-exec (literal ${JSON.stringify(path)}))`).join("");
        // process-exec sees Python's vnode, NOT its worker argument. Deny the
        // configured canonical interpreter and direct worker execution. Other
        // Python/dynamic routes cannot read real safetensors outside fixtures.
        const profile = Buffer.from(`(version 1)(allow default)(allow process-exec (literal "/bin/ps") (with no-sandbox))(deny process-exec (regex #"/voicelayer-test-stt-kernel-canary-v3$"))(deny file-read-data (regex #"/voicelayer-test-stt-weight-canary$"))(deny file-read-data (require-all (regex #"[.]safetensors$") ${outsideFixtureRoots}))(deny process-exec (require-all (regex #"(^|/)(whisper-cli|whisper-cpp|whisper-server|parakeet-worker[.]py|parakeet_worker[.]py)$") ${outsideFixtureRoots}))${runtimeRules}${weightRules}` + String.fromCharCode(0));
        const error = new BigUint64Array(1);
        if (library.symbols.sandbox_init(ptr(profile), 0, ptr(error)) !== 0) {
          const message = error[0] ? new CString(Number(error[0]) as import("bun:ffi").Pointer).toString() : "unknown";
          if (error[0]) library.symbols.sandbox_free_error(Number(error[0]) as import("bun:ffi").Pointer);
          throw new Error(`STT guard kernel policy failed: ${message}`);
        }
        library.close();
        const enforcedCanary = probe(canary), enforcedNeutral = probe(neutral);
        if (!deniedProbe(enforcedCanary) || !succeeded(enforcedNeutral) || !weightDenied(weight) ||
            !protectedRuntimes.every(runtimeDenied))
          throw new Error("STT guard kernel enforcement check failed " +
            JSON.stringify({ timeoutMs: probeTimeoutMs, canary: enforcedCanary, neutral: enforcedNeutral }));
        writeFileSync(join(runRoot, cacheName), JSON.stringify({ policy, roots, runtimes: protectedRuntimes, weights }),
          { mode: 0o400, flag: "wx" });
        process.env.VOICELAYER_TEST_STT_GUARD_ROOT = runRoot;
      }
    }
  } else {
    // This host cannot install the macOS descendant policy. Do not run an
    // unopted suite against an installed engine with only PATH interception.
    const dirs = [...(process.env.PATH ?? "").split(delimiter), "/usr/local/bin", "/usr/bin", "/opt/homebrew/bin"];
    assertNoInstalledStt(dirs, roots);
    if (protectedRuntimes.some(path => existsSync(path))) throw new Error("STT guard requires descendant enforcement for installed Parakeet runtime");
  }
  const fake = (path: string) => {
    try { const actual = realpathSync(path); return roots.some((root) => within(actual, root)) && !within(actual, bin); }
    catch { return false; }
  };
  return (cmd: unknown, env: NodeJS.ProcessEnv) => {
    const requestedPath = env.PATH ?? process.env.PATH ?? "";
    const runtimes = pythonMap(requestedPath);
    env.VOICELAYER_TEST_STT_PYTHON_MAP = JSON.stringify(runtimes);
    env.PATH = bin + delimiter + (Object.keys(runtimes).length ? pythonBin + delimiter : "") + requestedPath;
    env.VOICELAYER_TEST_STT_STUB_LOG = log;
    env.VOICELAYER_TEST_STT_CALLSITE = new Error().stack?.split("\n").filter((line) => !/stt-spawn-guard|setup\/preload/.test(line)).join("\n");
    env.VOICELAYER_TEST_STT_FIXTURE_ROOTS = JSON.stringify(roots);
    if (!Array.isArray(cmd) || typeof cmd[0] !== "string") return cmd;
    const configured = canonicalRuntime(env.VOICELAYER_PARAKEET_PYTHON);
    const executablePath = cmd[0].includes(sep) ? canonicalRuntime(cmd[0]) : canonicalRuntime(pythons.get(cmd[0]));
    const python = /^(python(?:\d+(?:\.\d+)*)?|Python)$/.test(basename(executablePath ?? cmd[0])) || (!!configured && executablePath === configured);
    if (isRealParakeetWorker(cmd[0], roots) || (python &&
        (isRealParakeetWorker(pythonScriptOperand(cmd.slice(1)), roots) ||
          (!!configured && executablePath === configured && !fake(configured))))) {
      env.VOICELAYER_TEST_STT_ENGINE = "parakeet";
      return [process.execPath, denied];
    }
    if (!tools.has(basename(cmd[0]))) return cmd;
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
