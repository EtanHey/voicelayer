#!/usr/bin/env bun
/**
 * c8-M2 (RM-memory P1, round 3): measured against the REAL installed mlx_lm.server.
 *
 *   POLISH_HF_HOME=<huggingface cache dir> bun scripts/measure-polish-cache.ts [--footprint]
 *
 * A standalone script, not a bun test: the test preload sandboxes test processes and denies reading model
 * weights (`src/__tests__/setup/stt-spawn-guard.ts`), so the real model cannot load under it. It touches no
 * VoiceLayer state: a private port, its own server processes. Synthetic prompts only. Exit 0 = PASS.
 *
 * Memory is measured as PHYSICAL FOOTPRINT (proc_pid_rusage ri_phys_footprint): MLX keeps its KV caches in
 * Metal buffers that `ps` RSS does not show (round 2 measured RSS flat while the cache held 1.89 GB).
 *
 * Default run, two configurations, sequential seeded requests shaped like ours (seed set => sequential path):
 *   previous: 4 entries + --prompt-cache-bytes 768 MiB (the round-1 arguments), no reset rule;
 *   ours:     our arguments + the daemon's reset rule (polishCacheResetNeeded on footprint growth over the
 *             smallest post-use sample, or the server's logged cache over budget). When the DETECTOR fires the
 *             script performs the RESET the daemon owes at idle (stop, relaunch, warm) and keeps measuring.
 * PASS requires: the previous arguments' retained growth exceeds the budget (the byte flag is not enforced),
 * ours never holds more than one sequence, the detector fired whenever ours went over budget, and every
 * retained (not-reset) ours sample stays within the budget. A run with zero resets and a 1.89 GB entry fails.
 * The production state machine (owed until idle, exactly once, next take polished) is proven separately by
 * src/__tests__/polish-budget-lifecycle.test.ts with fake servers.
 */
import { POLISH_CACHE_GROWTH_BUDGET_BYTES, polishCacheArgs, polishCacheResetNeeded, processFootprintMb } from "../src/stt-polish-server";
import { DEFAULT_POLISH_MODEL } from "../src/stt-polish";

if (!process.env.POLISH_HF_HOME) { console.error("set POLISH_HF_HOME to the huggingface cache directory"); process.exit(2); }
const BINARY = "/opt/homebrew/bin/mlx_lm.server";
const PORT = 18187;
const N = 4;
const MiB = 1024 * 1024;
const BUDGET_MB = POLISH_CACHE_GROWTH_BUDGET_BYTES / MiB;
const started = Date.now();
function step(what: string) { console.error(`[polish-cache-real-server] +${Math.round((Date.now() - started) / 1000)}s ${what}`); }

function synthetic(i: number, words: number): string {
  const out: string[] = [];
  for (let w = 0; w < words; w++) out.push(`item${i}w${w % 97} value ${(w * 7919 + i) % 1000}`);
  return out.join(" ");
}

function listenerPids(): number[] {
  const out = Bun.spawnSync(["lsof", "-nP", `-iTCP:${PORT}`, "-sTCP:LISTEN", "-t"], { stdout: "pipe", stderr: "pipe", env: process.env });
  return out.stdout.toString().split(/\s+/).filter(Boolean).map(Number);
}

async function startServer(extra: string[]) {
  if (listenerPids().length) throw new Error(`port ${PORT} is already in use; refusing to measure someone else's server`);
  const log: string[] = [];
  const proc = Bun.spawn([BINARY, "--model", DEFAULT_POLISH_MODEL, "--host", "127.0.0.1", "--port", String(PORT), ...extra], {
    stdout: "ignore", stderr: "pipe",
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
    if (proc.exitCode !== null) throw new Error(`real polish server exited ${proc.exitCode} during startup`);
    // Ready only when THIS child is the listener.
    if (listenerPids().includes(proc.pid)) {
      try { if ((await fetch(`http://127.0.0.1:${PORT}/v1/models`, { signal: AbortSignal.timeout(5_000) })).ok) { step(`server ${proc.pid} ready`); return { proc, log }; } } catch {}
    }
    await Bun.sleep(500);
  }
  await stopServer(proc);
  throw new Error("real polish server did not become ready");
}

async function stopServer(proc: ReturnType<typeof Bun.spawn>) {
  proc.kill("SIGTERM");
  const exited = await Promise.race([proc.exited.then(() => true), Bun.sleep(5_000).then(() => false)]);
  if (!exited) { proc.kill("SIGKILL"); await proc.exited; }
}

async function seeded(i: number, words: number) {
  const response = await fetch(`http://127.0.0.1:${PORT}/v1/chat/completions`, {
    method: "POST", headers: { "Content-Type": "application/json" }, signal: AbortSignal.timeout(300_000),
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
const fp = (pid: number) => processFootprintMb(pid) ?? NaN;

async function main(): Promise<number> {
  const report: Record<string, unknown> = { budget_mb: BUDGET_MB };

  // Previous arguments: no reset rule. Footprint growth over the post-warm baseline is what it retains.
  let { proc, log } = await startServer(["--prompt-cache-size", "4", "--prompt-cache-bytes", String(768 * MiB)]);
  try {
    await seeded(100, 50);
    const base = fp(proc.pid);
    const rows = [];
    for (let i = 0; i < N; i++) { await seeded(i, 1300); const f = fp(proc.pid); rows.push({ footprint_mb: f, growth_mb: f - base }); }
    await seeded(999, 5); // the server logs its cache size at the START of a request
    report.previous = { baseline_footprint_mb: base, rows, logged_cache_gb: lastCacheGb(log), max_sequences: maxSequences(log) };
  } finally { await stopServer(proc); }

  // Ours: one entry + the daemon's rule; when the detector fires, perform the reset it owes.
  ({ proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true })));
  let maxSeq = 0; let resets = 0; let detectorFires = 0; let worstRetainedMb = 0; let overWithoutDetector = 0;
  const rows = [];
  try {
    await seeded(100, 50);
    let base = fp(proc.pid);
    for (let i = 0; i < N; i++) {
      await seeded(i, 1300);
      const f = fp(proc.pid);
      if (f < base) base = f; // the daemon's baseline is the smallest post-use footprint
      const loggedGb = lastCacheGb(log);
      const fires = polishCacheResetNeeded(base, f) || (loggedGb ?? 0) * 1e9 > POLISH_CACHE_GROWTH_BUDGET_BYTES;
      const over = (f - base) * MiB > POLISH_CACHE_GROWTH_BUDGET_BYTES;
      if (over && !fires) overWithoutDetector++;
      rows.push({ footprint_mb: f, growth_mb: f - base, logged_cache_gb: loggedGb, detector_fired: fires });
      maxSeq = Math.max(maxSeq, maxSequences(log));
      if (fires) {
        detectorFires++; resets++;
        await stopServer(proc);
        ({ proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true })));
        await seeded(100, 50);
        base = fp(proc.pid);
        rows.push({ after_reset_footprint_mb: base });
      } else worstRetainedMb = Math.max(worstRetainedMb, f - base);
    }
    await seeded(999, 5);
    maxSeq = Math.max(maxSeq, maxSequences(log));
    report.ours = { rows, resets, detector_fires: detectorFires, worst_retained_growth_mb: worstRetainedMb, max_sequences: maxSeq };
  } finally { await stopServer(proc); }

  console.log(JSON.stringify(report, null, 2));
  const previous = report.previous as { rows: { growth_mb: number }[] };
  const checks = {
    previous_retains_over_budget: Math.max(...previous.rows.map(r => r.growth_mb)) > BUDGET_MB,
    ours_one_sequence: maxSeq <= 1,
    ours_detector_fired_whenever_over_budget: overWithoutDetector === 0,
    ours_reset_when_detector_fired: resets === detectorFires,
    ours_retained_growth_within_budget: worstRetainedMb <= BUDGET_MB,
  };
  console.log(JSON.stringify({ checks }));
  return Object.values(checks).every(Boolean) ? 0 : 1;
}

/** --footprint: does the physical footprint see the KV cache that RSS missed? One server, one big request. */
async function footprintCheck(): Promise<number> {
  const { proc, log } = await startServer(polishCacheArgs({ size: true, bytes: true }));
  try {
    await seeded(100, 50);
    const before = fp(proc.pid);
    await seeded(0, 1300);
    const after = fp(proc.pid);
    await seeded(999, 5);
    const report = { before_footprint_mb: before, after_footprint_mb: after, footprint_growth_mb: after - before,
      logged_cache_gb: lastCacheGb(log), detector_fires: polishCacheResetNeeded(before, after) };
    console.log(JSON.stringify(report));
    return (after - before) > BUDGET_MB && report.detector_fires ? 0 : 1;
  } finally { await stopServer(proc); }
}

process.exit(await (process.argv.includes("--footprint") ? footprintCheck() : main()));
