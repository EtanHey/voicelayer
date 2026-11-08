import { randomUUID } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { dlopen, ptr } from "bun:ffi";

const libc = (() => {
  if (process.platform !== "darwin" || !["arm64", "x64"].includes(process.arch)) return null;
  try { return dlopen("/usr/lib/libSystem.B.dylib", {
    sysctl: { args: ["ptr", "u32", "ptr", "ptr", "ptr", "u64"], returns: "i32" },
  }); } catch { return null; }
})();
function processInfo(pid: number): { birth: string; zombie: boolean } | null {
  if (!libc) return null;
  // 64-bit Darwin SDK sys/proc.h extern_proc: timeval@0, p_stat@36, p_pid@40.
  // KERN_PROC_PID is readable across users; proc_pidinfo is not.
  const mib = new Int32Array([1, 14, 1, pid]);
  const bytes = new Uint8Array(4096), size = new BigUint64Array([4096n]);
  if (libc.symbols.sysctl(ptr(mib), 4, ptr(bytes), ptr(size), null, 0) !== 0 || size[0]! < 44n) return null;
  const view = new DataView(bytes.buffer), seconds = view.getBigInt64(0, true), micros = view.getInt32(8, true);
  if (view.getInt32(40, true) !== pid || seconds <= 0n || micros < 0 || micros >= 1_000_000) return null;
  return { birth: `${seconds}:${micros}`, zombie: view.getUint8(36) === 5 }; // SZOMB
}
export const admissionOwnerProbe = {
  exists(pid: number): boolean {
    try { process.kill(pid, 0); return true; }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
      throw error;
    }
  },
  startTime(pid: number): string | null { return processInfo(pid)?.birth ?? null; },
  zombie(pid: number): boolean { return processInfo(pid)?.zombie === true; },
};
const waitingLogs = new Map<string, number>();
function logOnce(key: string, message: string): void {
  const now = Date.now();
  if (now - (waitingLogs.get(key) ?? -Infinity) < 60_000) return;
  waitingLogs.set(key, now);
  try { console.error(message); } catch { /* logging cannot alter reconciliation */ }
}
function retiredDirectory(ledger: string): string {
  const retired = ledger + ".retired";
  try { mkdirSync(retired, { mode: 0o700 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  const stat = lstatSync(retired);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error("UPDATE_GATE_UNSAFE_RETIRED_LEDGER");
  return retired;
}
function pruneRetired(ledger: string): void {
  const retired = ledger + ".retired";
  try { lstatSync(retired); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  retiredDirectory(ledger);
  const complete = readdirSync(retired).flatMap(name => {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(name)) return [];
    const dir = join(retired, name), stat = lstatSync(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) return [];
    const files = readdirSync(dir).sort();
    if (files.join(",") !== "reason.json,record.json") return [];
    for (const file of files) { const s = lstatSync(join(dir, file)); if (!s.isFile() || s.isSymbolicLink()) return []; }
    const reason = JSON.parse(readFileSync(join(dir, "reason.json"), "utf8"));
    if (!["PID_ABSENT", "PID_REUSED", "PID_ZOMBIE"].includes(reason.reason)) return [];
    return [{ dir, at: lstatSync(join(dir, "reason.json")).mtimeMs }];
  }).sort((a, b) => b.at - a.at || a.dir.localeCompare(b.dir));
  // Only exact completed retirement artifacts; never recurse or enter the live ledger.
  for (const { dir } of complete.slice(50)) {
    unlinkSync(join(dir, "record.json")); unlinkSync(join(dir, "reason.json")); rmdirSync(dir);
  }
}
/** Updater-only; caller holds G1. No age expiry and no mutex recovery. */
export function reconcileDeadAdmissions(path: string, names: string[]): string[] {
  const ledger = path + ".admissions", kept: string[] = [];
  for (const name of names) {
    const file = join(ledger, name);
    let reason: "PID_ABSENT" | "PID_REUSED" | "PID_ZOMBIE" | undefined, pid: number | undefined;
    let status = "UNVERIFIABLE", startTime: string | undefined, observed: string | null = null;
    try {
      const stat = lstatSync(file, { bigint: true });
      if (!stat.isFile() || stat.isSymbolicLink()) throw Error("unsafe registration");
      const record = JSON.parse(readFileSync(file, "utf8"));
      if (!Number.isSafeInteger(record.pid) || record.pid < 1 || record.pid > 2_147_483_647 ||
        record.token !== name || typeof record.incarnation !== "string" || !record.incarnation ||
        !Number.isSafeInteger(record.generation) || record.generation < 0) throw Error("invalid owner");
      pid = record.pid;
      let exists = true;
      try { exists = admissionOwnerProbe.exists(pid!); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "EPERM") throw error; }
      if (!exists) reason = "PID_ABSENT";
      else {
        observed = admissionOwnerProbe.startTime(pid!);
        if (typeof record.startTime === "string" && /^\d+:\d+$/.test(record.startTime)) {
          startTime = record.startTime;
          if (observed && observed !== startTime) reason = "PID_REUSED";
          else if (observed) status = "LIVE";
        } else if (record.startTime === undefined && observed) {
          const [seconds, micros] = observed.split(":").map(BigInt);
          // The original owner existed at write time. A later birth proves reuse,
          // including legacy records; elapsed age alone never proves anything.
          if (seconds! * 1_000_000_000n + micros! * 1000n > stat.mtimeNs) reason = "PID_REUSED";
        }
        if (!reason && admissionOwnerProbe.zombie(pid!)) reason = "PID_ZOMBIE";
      }
    } catch { /* Unverifiable remains blocking evidence. */ }
    if (!reason) {
      kept.push(name);
      logOnce(`${path}/${name}`, `[update-gate] withholder ${JSON.stringify(name)} pid=${pid ?? "unknown"} ${status}; registration retained`);
      continue;
    }
    try {
      const destination = join(retiredDirectory(ledger), randomUUID());
      mkdirSync(destination, { mode: 0o700 });
      writeFileSync(join(destination, "reason.json"), JSON.stringify({ name, pid, reason,
        startTime, observed, at: new Date().toISOString() }) + "\n", { flag: "wx", mode: 0o600 });
      renameSync(file, join(destination, "record.json"));
      waitingLogs.delete(`${path}/${name}`);
    } catch (error) {
      const detail = (error as NodeJS.ErrnoException).code ?? (error instanceof Error ? error.message : "UNKNOWN");
      logOnce(`${path}/${name}/reap`, `[update-gate] reap failed for ${JSON.stringify(name)}: ${detail}; recovery required`);
      throw error;
    }
  }
  try { pruneRetired(ledger); }
  catch (error) {
    logOnce(`${path}/retention`, `[update-gate] retired retention failed: ${(error as NodeJS.ErrnoException).code ?? "unsafe retirement evidence"}; recovery required`);
    throw error;
  }
  return kept;
}
