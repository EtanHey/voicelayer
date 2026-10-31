export function inlineCodeSpanEnds(input: string): Map<number, number> {
  // Fences divide inline parsing regions: a stray tick before a block cannot
  // pair with a tick in or after that block. Keep offsets in the original text.
  const fences = Array.from(input.matchAll(/^[ \t]{0,3}(`{3,}|~{3,})[^\r\n]*$/gm));
  const boundaries: { start: number; end: number }[] = [];
  let open: RegExpMatchArray | undefined;
  for (const fence of fences) {
    if (!open) { open = fence; continue; }
    if (fence[1][0] === open[1][0] && fence[1].length >= open[1].length && !fence[0].slice(fence[0].indexOf(fence[1]) + fence[1].length).trim()) {
      boundaries.push({ start: open.index!, end: fence.index! + fence[0].length }); open = undefined;
    }
  }
  let region = boundaries.length - 1;
  const runs = Array.from(input.matchAll(/`+/g));
  const nextRunByLength = new Map<number, number>();
  const closingRuns = new Map<number, number>();
  const openingOffsets = new Map<number, number>();
  for (let i = runs.length - 1; i >= 0; i--) {
    const run = runs[i];
    while (region >= 0 && run.index < boundaries[region].end) {
      nextRunByLength.clear();
      if (run.index >= boundaries[region].start) break;
      region--;
    }
    if (region >= 0 && run.index >= boundaries[region].start && run.index < boundaries[region].end) continue;
    let backslashes = 0;
    for (let at = run.index - 1; at >= 0 && input[at] === "\\"; at--) backslashes++;
    const escaped = backslashes % 2;
    const closing = nextRunByLength.get(run[0].length - escaped);
    if (closing !== undefined) {
      closingRuns.set(i, closing);
      openingOffsets.set(i, run.index + escaped);
    }
    nextRunByLength.set(run[0].length, i);
  }
  const ends = new Map<number, number>();
  for (let i = 0; i < runs.length; i++) {
    const closing = closingRuns.get(i), start = openingOffsets.get(i);
    if (closing === undefined || start === undefined) continue;
    ends.set(start, runs[closing].index + runs[closing][0].length);
    i = closing;
  }
  return ends;
}
