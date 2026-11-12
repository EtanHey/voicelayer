#!/usr/bin/env bun
/**
 * c8-M2 round 2 (RM-memory P1): measured against the REAL installed mlx_lm.server.
 *
 *   POLISH_HF_HOME=<huggingface cache dir> bun scripts/measure-polish-cache.ts
 *
 * A standalone script, not a bun test: the test preload sandboxes test processes and denies reading
 * model weights (`src/__tests__/setup/stt-spawn-guard.ts`), so the real model cannot load under it.
 * It touches no VoiceLayer state: a private port, its own server processes, nothing else. Exit 0 = PASS.
 *
 * Loads the 4B polish model twice (~2.3 GB each, one after the other) on a private port, never the
 * resident 8080. Run alone. Sends synthetic seeded requests shaped like ours (seed set => the server's
 * sequential path) and records RSS plus the server's own `Prompt Cache` accounting after each.
 *   - "previous" arguments (4 entries + --prompt-cache-bytes 768 MiB): the logged cache exceeds 768 MiB,
 *     proving the byte flag is not enforced on this path.
 *   - our arguments plus our measured-reset rule: at most one cached sequence, and the RSS growth past
 *     the post-launch baseline never stays above the budget (the rule restarts the server).
 */
import { POLISH_CACHE_GROWTH_BUDGET_BYTES, polishCacheArgs, polishCacheResetNeeded, processFootprintMb } from "../src/stt-polish-server";
import { DEFAULT_POLISH_MODEL } from "../src/stt-polish";

if (!process.env.POLISH_HF_HOME) { console.error("set POLISH_HF_HOME to the huggingface cache directory"); process.exit(2); }
const BINARY = "/opt/homebrew/bin/mlx_lm.server";
const PORT = 18187;
const N = 5;
const MiB = 1024 * 1024;

function synthetic(i: number, words: number): string {
  const out: string[] = [];
  for (let w = 0; w < words; w++) out.push(`item${i}w${w % 97} value ${(w * 7919 + i) % 1000}`);
  return out.join(" ");
}

const started = Date.now();
function step(what: string) { console.error(`[polish-cache-real-server] +${Math.round((Date.now() - started) / 1000)}s ${what}`); }

async function rssMb(pid: number): Promise<number> {
  const proc = Bun.spawn(["ps", "-o", "rss=", "-p", String(pid)], { stdout: "pipe", env: process.env });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return Math.round(Number(out.trim()) / 1024);
}

async function startServer(extra: string[]) {
  const log: string[] = [];
  const proc = Bun.spawn([BINARY, "--model", DEFAULT_POLISH_MODEL, "--host", "127.0.0.1", "--port", String(PORT), ...extra], {
    stdout: "pipe", stderr: "pipe",
    env: { ...process.env, HF_HOME: process.env.POLISH_HF_HOME!, HF_HUB_OFFLINE: "1" },
  });
  void (async () => {
    const reader = proc.stderr.getReader(); const decoder = new TextDecoder(); let pending = "";
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      const lines = (pending + decoder.decode(value, { stream: true })).split("\n"); pending = lines.pop() ?? "";
      log.push(...lines.filter(line => line.includes("Prompt Cache:")));
    }
  })();
  const deadline = Date.now() + 240_000;
  while (Date.now() < deadline) {
    try { if ((await fetch(`http://127.0.0.1:${PORT}/v1/models`)).ok) { step(`server ${proc.pid} ready`); return { proc, log }; } } catch {}
    if (proc.exitCode !== null) throw new Error(`real polish server exited ${proc.exitCode} during startup`);
    await Bun.sleep(500);
  }
  proc.kill("SIGKILL");
  throw new Error("real polish server did not become ready");
}

async function seeded(i: number, words: number) {
  const response = await fetch(`http://127.0.0.1:${PORT}/v1/chat/completions`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: DEFAULT_POLISH_MODEL, temperature: 0, seed: 0, max_tokens: 16, stream: false,
      messages: [{ role: "system", content: "Repeat the first word of the user text." }, { role: "user", content: synthetic(i, words) }] }),
  });
  if (!response.ok) throw new Error(`seeded request ${i} failed: ${response.status} ${(await response.text()).slice(0, 200)}`);
  await response.json();
  step(`request ${i} (${words} words) done`);
}

function lastCacheGb(log: string[]): number | null {
  const match = /Prompt Cache: (\d+) sequences, ([\d.]+) GB/.exec(log.at(-1) ?? "");
  return match ? Number(match[2]) : null;
}
function maxSequences(log: string[]): number {
  return Math.max(0, ...log.map(line => Number(/Prompt Cache: (\d+) sequences/.exec(line)?.[1] ?? 0)));
}

async function main(): Promise<number> {
  {
    const report: Record<string, unknown> = {};

    // Previous branch head: 4 entries + byte flag.
    let { proc, log } = await startServer(["--prompt-cache-size", "4", "--prompt-cache-bytes", String(768 * MiB)]);
    try {
      await seeded(100, 50);
      const base = await rssMb(proc.pid);
      const rows = [];
      for (let i = 0; i < N; i++) { await seeded(i, 1300); rows.push({ rss_mb: await rssMb(proc.pid) }); }
      await seeded(999, 5); // the server logs its cache size at the START of a request
      report.previous = { baseline_rss_mb: base, rows, logged_cache_gb: lastCacheGb(log), max_sequences: maxSequences(log) };
    } finally { proc.kill("SIGTERM"); await proc.exited; }

    // Ours: one entry + the daemon's reset rule applied after every request.
    ({ proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true })));
    let resets = 0; let worstGrowthMb = 0;
    try {
      await seeded(100, 50);
      let base = await rssMb(proc.pid);
      const rows = [];
      for (let i = 0; i < N; i++) {
        await seeded(i, 1300);
        const rss = await rssMb(proc.pid);
        const reset = polishCacheResetNeeded(base, rss);
        rows.push({ rss_mb: rss, growth_mb: rss - base, reset });
        if (reset) {
          resets++;
          proc.kill("SIGTERM"); await proc.exited;
          ({ proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true })));
          await seeded(100, 50);
          base = await rssMb(proc.pid);
        } else worstGrowthMb = Math.max(worstGrowthMb, rss - base);
      }
      await seeded(999, 5);
      report.ours = { rows, resets, worst_kept_growth_mb: worstGrowthMb, logged_cache_gb: lastCacheGb(log), max_sequences: maxSequences(log) };
    } finally { proc.kill("SIGTERM"); await proc.exited; }

    console.log(JSON.stringify(report, null, 2));
    const previous = report.previous as { logged_cache_gb: number; max_sequences: number };
    const ours = report.ours as { logged_cache_gb: number; max_sequences: number; worst_kept_growth_mb: number };
    const checks = {
      previous_byte_flag_not_enforced: previous.logged_cache_gb * 1e9 > 768 * MiB,
      ours_one_sequence: ours.max_sequences <= 1,
      ours_growth_within_budget: ours.worst_kept_growth_mb * MiB <= POLISH_CACHE_GROWTH_BUDGET_BYTES,
    };
    console.log(JSON.stringify({ checks }));
    return Object.values(checks).every(Boolean) ? 0 : 1;
  }
}

/** --footprint: does the physical footprint see the KV cache that RSS missed? One server, one big request. */
async function footprintCheck(): Promise<number> {
  const { proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true }));
  try {
    await seeded(100, 50);
    const before = { rss_mb: await rssMb(proc.pid), footprint_mb: processFootprintMb(proc.pid) };
    await seeded(0, 1300);
    const after = { rss_mb: await rssMb(proc.pid), footprint_mb: processFootprintMb(proc.pid) };
    await seeded(999, 5);
    const growth = (after.footprint_mb ?? 0) - (before.footprint_mb ?? 0);
    const report = { before, after, footprint_growth_mb: growth, logged_cache_gb: lastCacheGb(log),
      reset_rule_fires: before.footprint_mb !== null && after.footprint_mb !== null && polishCacheResetNeeded(before.footprint_mb, after.footprint_mb) };
    console.log(JSON.stringify(report));
    // The cache entry measured 1.89 GB in the full run; the footprint must see most of it.
    return growth * 1024 * 1024 > POLISH_CACHE_GROWTH_BUDGET_BYTES && report.reset_rule_fires ? 0 : 1;
  } finally { proc.kill("SIGTERM"); await proc.exited; }
}

process.exit(await (process.argv.includes("--footprint") ? footprintCheck() : main()));
