import { appendFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

export type VoiceTraceStage = "tool_received" | "admission_done" | "drain_start" | "drain_end" |
  "synth_start" | "synth_end" | "synth_fail" | "probe_start" | "probe_end" | "envelope_start" | "envelope_end" |
  "job_queued" | "player_spawn" | "player_exit_confirmed" | "recorder_spawn" | "first_pcm" |
  "first_vad_speech" | "end_decision" | "recorder_exit_confirmed" | "stt_start" | "stt_end" | "handler_returned";
type Fields = { conversation_id?: string; turn?: number; outcome?: string; engine?: string; warm_state?: string; route?: string };
type Trace = { request_id: string; seen: Set<VoiceTraceStage>; engine?: string };
const traces = new WeakMap<object, Trace>();
const namedTraces = new Map<string, Trace>();
function lookup(source: object | string | undefined): Trace | undefined {
  return typeof source === "string" ? namedTraces.get(source) : source ? traces.get(source) : undefined;
}
export function linkVoiceTrace(source: object | string | undefined, target: object): void {
  const trace = lookup(source);
  if (trace) traces.set(target, trace);
}
export function traceStage(source: object | string | undefined, stage: VoiceTraceStage, fields: Fields = {}): void {
  const path = process.env.VOICELAYER_TRACE_FILE;
  if (!path || !source) return;
  let trace = lookup(source);
  if (stage === "tool_received" || (!trace && typeof source === "string")) {
    trace = { request_id: typeof source === "string" ? source : randomUUID(), seen: new Set() };
    if (typeof source === "string") {
      if (namedTraces.size >= 128) namedTraces.clear();
      namedTraces.set(source, trace);
    } else traces.set(source, trace);
  }
  if (!trace) return;
  if (stage === "synth_fail" && !fields.engine && !trace.engine) return;
  if (stage === "synth_start") trace.engine = fields.engine;
  const engine = fields.engine ?? (stage === "synth_fail" || stage === "synth_end" ? trace.engine : undefined);
  if (stage === "synth_end" || stage === "synth_fail") trace.engine = undefined;
  trace.seen.add(stage);
  try {
    appendFileSync(path, JSON.stringify({ request_id: trace.request_id, clock_id: process.pid,
      stage, monotonic_ns: process.hrtime.bigint().toString(), conversation_id: fields.conversation_id,
      turn: fields.turn, outcome: fields.outcome, engine, warm_state: fields.warm_state, route: fields.route }) + "\n", { mode: 0o600 });
  } catch {}
}
export function traceStageOnce(source: object | undefined, stage: VoiceTraceStage): void {
  if (!lookup(source)?.seen.has(stage)) traceStage(source, stage);
}
export function traceExit(source: object | undefined, stage: "recorder_exit_confirmed", exited: Promise<number>): void {
  if (process.env.VOICELAYER_TRACE_FILE && lookup(source)) void exited.then(() => traceStage(source, stage), () => {});
}
