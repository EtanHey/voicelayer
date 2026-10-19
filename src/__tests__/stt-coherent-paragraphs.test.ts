import { describe, expect, test } from 'bun:test';
import { applyCoherentParagraphs, coherentParagraphsEnabled } from '../stt-coherent-paragraphs';
import { finalizeTranscriptionResultForSurface, shouldBuildBoundaryContext } from '../input';
import { readPolishControlsStatus } from '../polish-controls-status';

const tokens = (s: string): string[] => s.split(/\s+/u).filter(Boolean);
const paragraphs = (s: string): string[] => s.split('\n\n');
const sentences = (s: string): number => (s.match(/[.!?](?=\s|$)/gu) ?? []).length;

/** The only allowed edit: one horizontal space becomes "\n\n". */
function expectOnlyBreaksInserted(input: string, output: string): void {
  expect(tokens(output)).toEqual(tokens(input));
  expect(output.replace(/\n\n/gu, ' ')).toBe(input);
}

const deploy = [
  'We moved the deploy script into the release folder last week.',
  'The script now builds the bundle and signs it with the team key.',
  'Signing takes about two minutes on the older laptop.',
  'The bundle is uploaded to the storage bucket after that.',
];
const dinner = [
  'Anyway, for dinner tonight I want to try the new noodle place.',
  'They have a vegetarian menu and the reviews look really good.',
  'We should book a table for seven people around eight.',
  'My sister says the parking there is terrible on weekends.',
];

describe('coherent paragraphs', () => {
  test('a clear topic shift at a completed sentence becomes the paragraph break', () => {
    const input = [...deploy, ...dinner].join(' ');
    const output = applyCoherentParagraphs(input);
    expectOnlyBreaksInserted(input, output);
    expect(output).toBe(`${deploy.join(' ')}\n\n${dinner.join(' ')}`);
  });

  test('short dictations stay one paragraph', () => {
    const input = deploy.slice(0, 3).join(' ');
    expect(applyCoherentParagraphs(input)).toBe(input);
    expect(applyCoherentParagraphs('Hello. Anyway, goodbye.')).toBe('Hello. Anyway, goodbye.');
  });

  test('never breaks after an ellipsis, fragment, abbreviation or before a lowercase continuation', () => {
    const filler = 'This sentence carries on about the same build pipeline topic again.';
    for (const ending of ['and...', 'fu…', 'see Dr.', 'see e.g.']) {
      const input = [filler, filler, filler, `We talked about it ${ending} Anyway, the noodle place is good.`, filler, filler, filler].join(' ');
      const output = applyCoherentParagraphs(input);
      expectOnlyBreaksInserted(input, output);
      expect(output).not.toContain(`${ending}\n\n`);
    }
    const lower = [filler, filler, filler, 'It ended. then it carried on with more.', filler, filler, filler].join(' ');
    expect(applyCoherentParagraphs(lower)).not.toContain('ended.\n\nthen');
  });

  test('never breaks after an initial, an unlisted abbreviation, a URL or a dotted token', () => {
    const left = 'The deployment pipeline builds a signed application bundle for the release server every morning. ';
    const right = 'Smith manages restaurant bookings and dinner menus for large parties on busy holiday weekends. ';
    for (const token of ['J.', 'A.', 'Capt.', 'Jan.', 'Sept.', 'approx.', 'https://example.com/help?', 'https://example.com/help!',
      'example.com.', 'www.example.org.', 'v2.3.', 'version 3.5.', 'me@example.com.', 'docs/setup.md.']) {
      const input = left.repeat(4) + 'We assigned the next task to ' + token + ' ' + right.repeat(5);
      const output = applyCoherentParagraphs(input);
      expectOnlyBreaksInserted(input, output);
      expect(output).not.toContain(`${token}\n\n`);
    }
  });

  // Sol PARA1 R2 #1: a finite list always misses one. Any short capitalised
  // token before a capitalised word is ambiguous, and an initial is one
  // grapheme, however many code points it is written with.
  test('never breaks after any short capitalised form or a combining-mark initial', () => {
    const left = 'The deployment pipeline builds a signed application bundle for the release server every morning. ';
    const right = 'Smith manages restaurant bookings and dinner menus for large parties on busy holiday weekends. ';
    for (const token of ['Maj.', 'Cpl.', 'Asst.', 'Assoc.', 'É.', 'Brig.', 'Hosp.', 'Ǻ.', '"É."']) {
      const input = left.repeat(4) + 'We assigned the next task to ' + token + ' ' + right.repeat(5);
      const output = applyCoherentParagraphs(input);
      expectOnlyBreaksInserted(input, output);
      expect(output).not.toContain(`${token}\n\nSmith`);
    }
  });

  test('a single soft line wrap does not disable the stage', () => {
    const input = [...deploy.slice(0, 2), `${deploy[2]}\n${deploy[3]}`, ...dinner].join(' ');
    expect(applyCoherentParagraphs(input)).toContain('\n\nAnyway');
  });

  test('existing line breaks and numbered lists are left alone', () => {
    const input = `${deploy.join(' ')}\n\n${dinner.join(' ')}`;
    expect(applyCoherentParagraphs(input)).toBe(input);
    const list = `${deploy.join(' ')}\n1. first item.\n2. second item. ${dinner.join(' ')}`;
    expect(applyCoherentParagraphs(list)).toBe(list);
  });

  test('a run of same-topic sentences is split into paragraphs of roughly 3 to 8 sentences', () => {
    const run = Array.from({ length: 24 }, (_, i) =>
      `Point number ${i} is about the deploy script and the release bundle signing.`).join(' ');
    const output = applyCoherentParagraphs(run);
    expectOnlyBreaksInserted(run, output);
    const parts = paragraphs(output);
    expect(parts.length).toBeGreaterThanOrEqual(3);
    for (const part of parts) {
      expect(sentences(part)).toBeGreaterThanOrEqual(3);
      expect(sentences(part)).toBeLessThanOrEqual(8);
    }
  });

  test('a sentence that continues the previous one is not split off', () => {
    const input = [
      ...deploy,
      'I chose the smaller model.',
      'Because it is cheaper than the default one we had.',
      'It is a bit slower but the quality is higher anyway.',
      ...deploy.slice(0, 2),
    ].join(' ');
    expect(applyCoherentParagraphs(input)).not.toContain('\n\nBecause');
  });

  test('word identity holds for every input, including Hebrew, retractions and fragments', () => {
    const pool = [
      'I want the, I mean the other one.', 'fu… function names stay.', 'שלום לכולם.', 'Wait, I\'m checking.',
      'Okay.', 'Anyway, next topic here.', 'Also, the café́ bill.', 'Because it matters.', 'What about that?',
      'Dr. Smith said so.', 'and... then it stopped', 'Now the transcriber though.', 'As for the voice, keep it!',
      'It ended — sort of.', '"Quoted words here."', 'So, yeah.',
    ];
    let seed = 7;
    const rand = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    for (let n = 0; n < 300; n++) {
      const count = 1 + Math.floor(rand() * 40);
      const input = Array.from({ length: count }, () => pool[Math.floor(rand() * pool.length)]).join(' ');
      expectOnlyBreaksInserted(input, applyCoherentParagraphs(input));
    }
  });

  test('toggle is off by default and on when set', () => {
    expect(coherentParagraphsEnabled({})).toBe(false);
    expect(coherentParagraphsEnabled({ VOICELAYER_STT_COHERENT_PARAGRAPHS: '1' })).toBe(true);
    expect(coherentParagraphsEnabled({ VOICELAYER_STT_COHERENT_PARAGRAPHS: '0' })).toBe(false);
    const status = readPolishControlsStatus({ VOICELAYER_STT_COHERENT_PARAGRAPHS: '1', VOICELAYER_PROCESSING_SETTINGS_PATH: '/nonexistent/p.json' });
    expect(status.coherent_paragraphs).toEqual({ source: 'environment', raw: '1', effective: true });
  });

  test('coherent paragraphs do not need the pause map', () => {
    const long = 'x'.repeat(500);
    expect(shouldBuildBoundaryContext(long, {})).toBe(true);
    expect(shouldBuildBoundaryContext(long, { VOICELAYER_STT_COHERENT_PARAGRAPHS: '1' })).toBe(false);
    expect(shouldBuildBoundaryContext(long, { VOICELAYER_STT_COHERENT_PARAGRAPHS: '1', VOICELAYER_STT_SMART_BOUNDARIES: '1' })).toBe(true);
  });

  test('finalize applies it without any audio evidence when enabled', async () => {
    const input = [...deploy, ...dinner].join(' ');
    const base = { QA_VOICE_STT_POLISH: 'off', VOICELAYER_PROCESSING_SETTINGS_PATH: '/nonexistent/p.json' };
    const off = await finalizeTranscriptionResultForSurface(input, null, base);
    const on = await finalizeTranscriptionResultForSurface(input, null, { ...base, VOICELAYER_STT_COHERENT_PARAGRAPHS: '1' });
    expect(off.text).not.toContain('\n\n');
    expect(on.text).toContain('\n\n');
    expectOnlyBreaksInserted(off.text, on.text);
  });
});
