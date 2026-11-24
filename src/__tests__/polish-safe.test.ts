import { expect, test } from 'bun:test';
import { buildPolishSystemPrompt } from '../stt-polish';
import { readFileSync } from 'node:fs';
test('formatting instructions carry no copyable few-shot responses', () => {
  for (const retry of [undefined, 'noop', 'rejected'] as const) {
    expect(buildPolishSystemPrompt(retry)).not.toMatch(/(?:Input|Output):/);
  }
});
test('rejection diagnostics do not interpolate invented identifiers or persist candidate text', () => {
  const source = readFileSync(new URL('../stt-polish.ts', import.meta.url), 'utf8');
  expect(source).not.toContain('${inventedIdentifier}');
  expect(source).toContain('polished_text: result.status === "rejected" ? null : result.polishedText');
});
