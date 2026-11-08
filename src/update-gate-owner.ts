import { randomUUID } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { dlopen, ptr } from "bun:ffi";

// Darwin proc_bsdinfo: SDK sys/proc_info.h, 136 bytes; start timeval at 120/128.
const libproc = (() => {
  if (process.platform !== "darwin") return null;
  try { return dlopen("/usr/lib/libproc.dylib", {
    proc_pidinfo: { args: ["i32", "i32", "u64", "ptr", "i32"], returns: "i32" },
  }); } catch { return null; } // Missing OS proof keeps legacy/unverifiable owners.
})();
export const admissionOwnerProbe = {
  exists(pid: number): boolean {
    try { process.kill(pid, 0); return true; }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
      throw error; // EPERM and all other failures are not evidence of death.
    }
  },
  startTime(pid: number): string | null {
    if (!libproc) return null;
    const bytes = new Uint8Array(136), view = new DataView(bytes.buffer);
    if (libproc.symbols.proc_pidinfo(pid, 3, 0, ptr(bytes), bytes.length) !== bytes.length ||
      view.getUint32(12, true) !== pid || view.getBigUint64(120, true) === 0n) return null;
    return `${view.getBigUint64(120, true)}:${view.getBigUint64(128, true)}`;
  },
};

/** Updater-only; caller holds G1. Never inspect age or reap the mutex itself. */
export function reconcileDeadAdmissions(path: string, names: string[]): string[] {
  const ledger = path + ".admissions", kept: string[] = [];
  for (const name of names) {
    const file = join(ledger, name);
    let reason: "PID_ABSENT" | "PID_REUSED" | undefined, pid: number | undefined;
    let status = "UNVERIFIABLE", startTime: string | undefined, observed: string | null = null;
    try {
      const stat = lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink()) throw Error("unsafe registration");
      const record = JSON.parse(readFileSync(file, "utf8"));
      if (!Number.isSafeInteger(record.pid) || record.pid < 1 || record.pid > 2_147_483_647 ||
        record.token !== name || typeof record.incarnation !== "string" || !record.incarnation ||
        !Number.isSafeInteger(record.generation) || record.generation < 0) throw Error("invalid owner");
      pid = record.pid;
      if (!admissionOwnerProbe.exists(pid!)) reason = "PID_ABSENT";
      else if (typeof record.startTime === "string" && /^\d+:\d+$/.test(record.startTime)) {
        startTime = record.startTime;
        observed = admissionOwnerProbe.startTime(pid!);
        if (observed && observed !== startTime) reason = "PID_REUSED";
        else if (observed) status = "LIVE";
      }
    } catch { /* Unverifiable is blocking evidence, never absence. */ }
    if (!reason) {
      kept.push(name);
      console.error(`[update-gate] withholder ${JSON.stringify(name)} pid=${pid ?? "unknown"} ${status}; registration retained`);
      continue;
    }
    const retired = ledger + ".retired";
    try { mkdirSync(retired, { mode: 0o700 }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    const stat = lstatSync(retired);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error("UPDATE_GATE_UNSAFE_RETIRED_LEDGER");
    const destination = join(retired, randomUUID());
    mkdirSync(destination, { mode: 0o700 });
    // Write proof first. If it fails, the original registration still blocks.
    writeFileSync(join(destination, "reason.json"), JSON.stringify({ name, pid, reason,
      startTime, observed, at: new Date().toISOString() }) + "\n", { flag: "wx", mode: 0o600 });
    renameSync(file, join(destination, "record.json"));
  }
  return kept;
}
