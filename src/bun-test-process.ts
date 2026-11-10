import { readFileSync } from "node:fs";

/** Bun rewrites JS argv to the current test file. Read this process's original
 * invocation instead: NODE_ENV and preload env markers also reach plain children. */
export function isBunTestProcess(): boolean {
  if (!process.versions.bun) return false;
  let argv: string[];
  try {
    if (process.platform === "darwin") {
      const { dlopen, read, CString } = require("bun:ffi") as typeof import("bun:ffi");
      const library = dlopen("/usr/lib/libSystem.B.dylib", {
        _NSGetArgc: { args: [], returns: "ptr" },
        _NSGetArgv: { args: [], returns: "ptr" },
      });
      try {
        const argc = read.i32(library.symbols._NSGetArgc()!);
        if (argc < 1 || argc > 65_536) throw new Error("invalid process argc");
        const pointers = read.ptr(library.symbols._NSGetArgv()!) as import("bun:ffi").Pointer;
        argv = Array.from({ length: argc }, (_, i) =>
          new CString(read.ptr(pointers, i * 8) as import("bun:ffi").Pointer).toString());
      } finally { library.close(); }
    } else if (process.platform === "linux") {
      argv = readFileSync("/proc/self/cmdline", "utf8").split("\0").filter(Boolean);
    } else {
      throw new Error("original process arguments unavailable on this platform");
    }
  } catch {
    // Unknown identity is never permission for an unisolated test environment.
    return process.env.NODE_ENV === "test";
  }
  const valueOptions = new Set(["--cwd", "--config", "-c", "--preload", "-r", "--env-file",
    "--conditions", "--define", "--loader", "--tsconfig-override", "--extension-order"]);
  for (let i = 1; i < argv.length; i++) {
    const arg = argv[i]!;
    if (["-e", "--eval", "-p", "--print"].includes(arg) || /^(--eval|--print)=/.test(arg)) return false;
    if (arg === "--") return argv[i + 1] === "test";
    if (!arg.startsWith("-")) return arg === "test";
    if (valueOptions.has(arg)) i++;
  }
  return false;
}
