export function inlineCodeSpanEnds(input: string): Map<number, number> {
  const runs = Array.from(input.matchAll(/`+/g));
  const nextRunByLength = new Map<number, number>();
  const closingRuns = new Map<number, number>();
  const openingOffsets = new Map<number, number>();
  for (let i = runs.length - 1; i >= 0; i--) {
    const run = runs[i];
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
