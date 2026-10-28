import { readFileSync } from "node:fs";
import { z } from "zod";

const eventSchema = z.object({ request_id: z.string(), clock_id: z.number().int().optional(),
  stage: z.string(), monotonic_ns: z.string().regex(/^\d+$/).transform(value => BigInt(value)) });
type Event = z.infer<typeof eventSchema>;
export function analyzeVoiceTrace(ndjson: string): string {
  const requests = new Map<string, Event[]>();
  for (const line of ndjson.split("\n").filter(line => line.trim())) {
    const event = eventSchema.parse(JSON.parse(line));
    const key = `${event.request_id} (clock ${event.clock_id ?? "unspecified"})`;
    const events = requests.get(key) ?? [];
    events.push(event); requests.set(key, events);
  }
  return [...requests].map(([id, events]) => {
    events.sort((a, b) => a.monotonic_ns < b.monotonic_ns ? -1 : a.monotonic_ns > b.monotonic_ns ? 1 : 0);
    const first = (stage: string) => events.find(event => event.stage === stage)?.monotonic_ns;
    const last = (stage: string, before: bigint | undefined) => before === undefined ? undefined :
      events.findLast(event => event.stage === stage && event.monotonic_ns <= before)?.monotonic_ns;
    const span = (start: bigint | undefined, end: bigint | undefined) =>
      start === undefined || end === undefined || end < start ? "UNMEASURED" : `${(Number(end - start) / 1e6).toFixed(3)} ms`;
    return `${id}\n  tool→player_spawn (proxy): ${span(first("tool_received"), first("player_spawn"))}\n` +
      `  output onset: UNMEASURED\n  question_end→first_pcm: ${span(last("player_exit_confirmed", first("first_pcm")), first("first_pcm"))}\n` +
      `  last_speech→tool_result: ${span(last("last_speech", first("tool_result_emitted")), first("tool_result_emitted"))}\n` +
      `  recorder_exit_confirmed: ${first("recorder_exit_confirmed") === undefined ? "UNMEASURED" : "observed"}`;
  }).join("\n");
}
if (import.meta.main) {
  const path = process.argv[2];
  if (!path) throw new Error("Usage: bun scripts/measure-voice-turn-latency.ts <trace.ndjson>");
  console.log(analyzeVoiceTrace(readFileSync(path, "utf8")));
}
