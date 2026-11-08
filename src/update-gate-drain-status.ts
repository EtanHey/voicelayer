import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { updateGateFilePath } from "./paths";
export type PendingParticipant = { participant: "native" | "daemon"; pid?: number; incarnation?: string; version?: string; reply: string };
/** Diagnostics only; none of these observations can authorize a transition. */
export function describeResidentParticipants(): PendingParticipant[] {
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") return (["native", "daemon"] as const)
    .map(participant => ({ participant, reply: "no reply" }));
  let version = "unknown", rows: Array<{ pid: number; parent: number; command: string }> = [];
  try {
    const result = Bun.spawnSync(["/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-",
      "/Applications/VoiceBar.app/Contents/Info.plist"], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
    if (result.exitCode === 0 && /^[\w.+-]{1,60}$/.test(result.stdout.toString().trim())) version = result.stdout.toString().trim();
    const ps = Bun.spawnSync(["/bin/ps", "-axo", "pid=,ppid=,args="], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
    if (ps.exitCode === 0) rows = ps.stdout.toString().split("\n").flatMap(line => {
      const match = /^\s*(\d+)\s+(\d+)\s+(.+)$/.exec(line);
      return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3]! }] : [];
    });
  } catch { /* unknown metadata remains visible */ }
  if (version !== "unknown") version = "installed-bundle:" + version;
  const natives = rows.filter(row => /(?:^|\/)VoiceBar(?:\s|$)/.test(row.command));
  const native = natives.length === 1 ? natives[0] : undefined;
  const daemons = rows.filter(row => row.parent === native?.pid && /mcp-server-daemon/.test(row.command));
  return [{ participant: "native", pid: native?.pid, version, reply: "no reply" },
    { participant: "daemon", pid: daemons.length === 1 ? daemons[0]?.pid : undefined, version, reply: "no reply" }];
}
export function drainLedgerStatus(): string[] {
  const path = updateGateFilePath() + ".admissions";
  try {
    if (!lstatSync(path).isDirectory() || lstatSync(path).isSymbolicLink()) return ["ledger UNKNOWN"];
    return readdirSync(path).map(token => {
      try {
        const file = join(path, token);
        if (!lstatSync(file).isFile() || lstatSync(file).isSymbolicLink()) return "ledger token=unknown kind=unknown pid=unknown";
        const entry = JSON.parse(readFileSync(file, "utf8"));
        const kind = entry.kind === "capture" || entry.kind === "speech" ? entry.kind : "voice";
        return `ledger token=${/^[\w-]{1,80}$/.test(token) ? token : "unknown"} kind=${kind} pid=${Number.isSafeInteger(entry.pid) && entry.pid > 0 ? entry.pid : "unknown"}`;
      } catch { return "ledger token=unknown kind=unknown pid=unknown"; }
    });
  } catch { return ["ledger UNKNOWN"]; }
}
export function formatDrainStatus(pending: PendingParticipant[], ledger: string[]): string {
  return [...pending.map(p => `${p.participant} pid=${p.pid ?? "unknown"} incarnation=${p.incarnation ?? "unknown"}: participant did not acknowledge (version ${p.version ?? "unknown"}); last reply=${p.reply}`), ...ledger].join("; ") || "awaiting locked drain proof";
}
