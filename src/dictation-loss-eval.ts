/** Offline hypothesis alignment. Disagreements are candidates, not ground truth. */
import type { STTPolishFailureKind, STTPolishStatus } from "./stt-polish";
export const LOSS_CLASSES = ["number/unit", "ending/tail", "filler/hedge", "repetition/retraction", "seam/chunk-boundary", "other"] as const;
export type LossClass = typeof LOSS_CLASSES[number];
export interface WordEdit { kind: "delete" | "insert" | "substitute"; before: string; after: string; index: number; tags: LossClass[] }
const NUMBER_WORD = /^(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|percent|percentage|dollars?|cents?|euros?|pounds?|k|kb|mb|gb|kilobytes)$/u;
export function lossWords(text: string): string[] {
  // Only well-formed grouped thousands may contain commas; lists remain separate tokens.
  return text.toLowerCase().match(/(?<![\p{L}\p{N},])[$€£]?\d{1,3}(?:,\d{3})+(?:\.\d+)?[kmb]?[%$€£]?(?![\p{L}\p{N},])|[$€£]?[\p{L}\p{N}]+(?:['’.][\p{L}\p{N}]+)*[%$€£]?|[$€£%]/gu)?.map(w => w.replaceAll(",", "").replace(/’/g, "'")) ?? [];
}
export function alignLoss(before: string, after: string, seamWords: number[] = []): WordEdit[] {
  const a = lossWords(before), b = lossWords(after), width = b.length + 1;
  if ((a.length + 1) * width > 20_000_000) throw new Error("Alignment exceeds 20M cells");
  const cells = new Uint32Array((a.length + 1) * width);
  for (let i = 0; i <= a.length; i++) cells[i * width] = i;
  for (let j = 0; j <= b.length; j++) cells[j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) {
    cells[i * width + j] = Math.min(cells[(i - 1) * width + j]! + 1, cells[i * width + j - 1]! + 1,
      cells[(i - 1) * width + j - 1]! + Number(a[i - 1] !== b[j - 1]));
  }
  const edits: WordEdit[] = [];
  let i = a.length, j = b.length;
  while (i || j) {
    if (i && j && a[i - 1] === b[j - 1]) { i--; j--; continue; }
    let kind: WordEdit["kind"], old = "", next = "";
    if (i && j && cells[i * width + j] === cells[(i - 1) * width + j - 1]! + 1) {
      kind = "substitute"; old = a[--i]!; next = b[--j]!;
    } else if (i && cells[i * width + j] === cells[(i - 1) * width + j]! + 1) { kind = "delete"; old = a[--i]!; }
    else { kind = "insert"; next = b[--j]!; }
    const tags: LossClass[] = [];
    if (/[\p{N}%$€£]/u.test(old + next) || NUMBER_WORD.test(old)) tags.push("number/unit");
    if (/^(um|uh|er|maybe|perhaps|probably|like|actually|basically)$/u.test(old)) tags.push("filler/hedge");
    if (old && (a[i - 1] === old || a[i + 1] === old || /^(sorry|mean|rather|no)$/u.test(old))) tags.push("repetition/retraction");
    if (seamWords.some(s => Math.abs(s - i) <= 2)) tags.push("seam/chunk-boundary");
    edits.push({ kind, before: old, after: next, index: i, tags });
  }
  const deleted = new Set(edits.filter(e => e.kind === "delete").map(e => e.index));
  let tailStart = a.length;
  while (tailStart > 0 && deleted.has(tailStart - 1)) tailStart--;
  for (const edit of edits) {
    if (edit.kind === "delete" && edit.index >= tailStart) edit.tags.push("ending/tail");
    if (!edit.tags.length) edit.tags.push("other");
  }
  return edits.reverse();
}
export function stageEdges(stages: { name: string; text: string }[]) {
  return stages.slice(1).map((stage, index) => ({ from: stages[index]!.name, to: stage.name,
    edits: alignLoss(stages[index]!.text, stage.text) }));
}
export function referenceComparisons({ ungated, gated, raw, finalText, seamWords = [] }: {
  ungated: string; gated: string; raw: string; finalText: string; seamWords?: number[];
}) {
  return {
    referenceGatedVsRaw: alignLoss(gated, raw),
    referenceVsFinal: alignLoss(gated, finalText, seamWords),
    referenceUngatedVsRaw: alignLoss(ungated, raw),
    referenceUngatedVsFinal: alignLoss(ungated, finalText),
  };
}
export function referenceSkipReason(text: string): string | null {
  return text.trim() ? null : "empty independent reference (silent or undecodable; not proof of silence)";
}
export interface PolishReplayEvidence {
  status: STTPolishStatus;
  failureKind?: STTPolishFailureKind | null;
  edges: ReturnType<typeof stageEdges>;
}
export function eligibleReplayEdges(replay: PolishReplayEvidence) {
  return replay.edges.filter(edge => edge.to !== "polish" || replay.status === "applied");
}
export function summarizePolishReplays(replays: readonly PolishReplayEvidence[]) {
  const statuses = new Map<STTPolishStatus, number>();
  const failures = new Map<string, number>();
  for (const replay of replays) {
    statuses.set(replay.status, (statuses.get(replay.status) ?? 0) + 1);
    if (replay.failureKind) failures.set(replay.failureKind, (failures.get(replay.failureKind) ?? 0) + 1);
  }
  const applied = replays.filter(replay => replay.status === "applied");
  const edits = applied.flatMap(replay => replay.edges.filter(edge => edge.to === "polish").flatMap(edge => edge.edits));
  return { total: replays.length, applied: applied.length, statuses: Object.fromEntries(statuses), failures: Object.fromEntries(failures),
    appliedDeletedTokens: applied.length ? edits.filter(e => e.kind === "delete").length : null,
    appliedSubstitutions: applied.length ? edits.filter(e => e.kind === "substitute").length : null };
}
