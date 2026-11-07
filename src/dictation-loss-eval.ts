/** Offline hypothesis alignment. Disagreements are candidates, not ground truth. */
export const LOSS_CLASSES = ["number/unit", "ending/tail", "filler/hedge", "repetition/retraction", "seam/chunk-boundary", "other"] as const;
export type LossClass = typeof LOSS_CLASSES[number];
export interface WordEdit { kind: "delete" | "insert" | "substitute"; before: string; after: string; index: number; tags: LossClass[] }
export function lossWords(text: string): string[] {
  return text.toLowerCase().match(/[$€£]?[\p{L}\p{N}]+(?:[,'’.][\p{L}\p{N}]+)*[%$€£]?|[$€£%]/gu)?.map(w => w.replace(/(?<=\d),(?=\d)/g, "").replace(/’/g, "'")) ?? [];
}
export function alignLoss(before: string, after: string, seamWords: number[] = [], tailWords = 8): WordEdit[] {
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
    if (/[\d%$€£]/u.test(old + next) || /^(zero|one|two|three|four|five|six|seven|eight|nine|ten|thirty|thousand|hundred|million|percent|dollars|kilobytes)$/u.test(old)) tags.push("number/unit");
    if (kind !== "insert" && i >= Math.max(0, a.length - tailWords)) tags.push("ending/tail");
    if (/^(um|uh|er|maybe|perhaps|probably|like|actually|basically)$/u.test(old)) tags.push("filler/hedge");
    if (old && (a[i - 1] === old || a[i + 1] === old || /^(sorry|mean|rather|no)$/u.test(old))) tags.push("repetition/retraction");
    if (seamWords.some(s => Math.abs(s - i) <= 2)) tags.push("seam/chunk-boundary");
    edits.push({ kind, before: old, after: next, index: i, tags: tags.length ? tags : ["other"] });
  }
  return edits.reverse();
}
export function stageEdges(stages: { name: string; text: string }[]) {
  return stages.slice(1).map((stage, index) => ({ from: stages[index]!.name, to: stage.name,
    edits: alignLoss(stages[index]!.text, stage.text) }));
}
