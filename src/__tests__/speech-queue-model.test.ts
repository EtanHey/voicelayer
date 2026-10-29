import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { z } from "zod";
import { SelectionReadQueue, type SelectionReadQueueState } from "../selection-read-queue";

const corpus = z.array(z.object({
  trace: z.array(z.number().int()),
  pending: z.number().int(),
  started: z.array(z.number().int()),
  visible: z.object({ count: z.number().int(), current_request_id: z.string().nullable() }),
  result: z.string(),
})).min(1);
const path = process.env.VOICELAYER_SPEECH_QUEUE_MODEL_CASES;

test.skipIf(!path)("TLC reachable transitions conform to the real selection queue", () => {
  if (!path) throw new Error("Run formal/speech-queue/check.sh to generate TLC cases");
  const cases = corpus.parse(JSON.parse(readFileSync(path, "utf8")));
  for (const row of cases) {
    const started: number[] = [];
    let visible: SelectionReadQueueState = { count: 0, current_request_id: null };
    let owner: string | undefined;
    const queue = new SelectionReadQueue(read => {
      const old = owner;
      owner = read.requestId;
      started.push(Number(read.requestId));
      if (old) queue.settled(old, "stopped");
    }, state => { visible = state; }, 2);
    let result = "none";
    for (const op of row.trace) {
      const id = (op - 1) % 4 + 1;
      result = "none";
      if (op <= 8) result = queue.submit({ admission: { run: work => work(), release() {} }, requestId: String(id), text: "identical text",
        textHash: "a".repeat(64), profile: "auto" }, op <= 4);
      else if (op <= 12) result = queue.next(String(id));
      else if (op <= 24) queue.settled(String(id), op <= 16 ? "completed" : op <= 20 ? "stopped" : "failed");
      else if (op === 25) queue.suspend();
      else if (op === 26) queue.clear();
      else { owner = String(op - 26); queue.own(owner); }
    }
    expect({ pending: queue.pendingCount, started, visible, result }, `TLC trace ${row.trace}`).toEqual({
      pending: row.pending, started: row.started, visible: row.visible, result: row.result,
    });
  }
  console.log(`Replayed ${cases.length} TLC reachable transitions against SelectionReadQueue`);
});
