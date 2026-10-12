import { describe, expect, test } from 'bun:test';
import { applyPauseParagraphs, pauseParagraphsEnabled } from '../stt-paragraphs';
import { buildBoundaryContext, finalizeTranscriptionResultForSurface } from '../input';
import { processingEnv, setProcessingSetting } from '../processing-settings';
import { readPolishControlsStatus } from '../polish-controls-status';
import { parseCommand } from '../socket-protocol';
import { TEST_TMP } from './setup/test-tmp';

const a = 'First we describe the original problem and keep every single detail. '.repeat(5).trim();
const b = 'Next we explain the proposed solution and preserve all the spoken words. '.repeat(5).trim();
const c = 'Finally we check the outcome and report what the evidence actually proves. '.repeat(5).trim();
const text = `${a} ${b} ${c}`;
const segments = [
  { text: a, startS: 0, endS: 20 },
  { text: b, startS: 23, endS: 43 },
  { text: c, startS: 43.5, endS: 64 },
];
const pauses = [{ startS: 20.1, endS: 23 }, { startS: 43, endS: 43.5 }];

describe('pause paragraphs', () => {
  test('a long relative pause breaks only at its existing sentence end', () => {
    expect(applyPauseParagraphs(text, segments, pauses)).toBe(`${a}\n\n${b} ${c}`);
  });
  test('non-whitespace bytes are identical, including Hebrew, combining marks and fragments', () => {
    const input = text.replace('original', 'מקורי').replace('solution', 'cafe\u0301 fu…');
    const evidence = segments.map(s => ({ ...s, text: s.text.replace('original', 'מקורי').replace('solution', 'cafe\u0301 fu…') }));
    const output = applyPauseParagraphs(input, evidence, pauses);
    expect(output).toContain('\n\n');
    expect(Buffer.from(output.replace(/\s/gu, ''))).toEqual(Buffer.from(input.replace(/\s/gu, '')));
  });
  test('no evidence, invalid times and short text leave input verbatim', () => {
    expect(applyPauseParagraphs(text, [], pauses)).toBe(text);
    expect(applyPauseParagraphs(text, segments, [])).toBe(`${a}\n\n${b} ${c}`); // segment gaps are evidence too
    expect(applyPauseParagraphs(text, segments.map(s => ({ ...s, endS: NaN })), pauses)).toBe(text);
    expect(applyPauseParagraphs('Hello. Goodbye.', [{ text: 'Hello.', startS: 0, endS: 1 }, { text: 'Goodbye.', startS: 6, endS: 7 }], [])).toBe('Hello. Goodbye.');
    expect(applyPauseParagraphs(text, segments.map((s,i) => ({ ...s, startS: i*20, endS: (i+1)*20 })), [])).toBe(text);
  });
  test('short pauses and pauses mid-sentence cannot introduce a sentence end', () => {
    expect(applyPauseParagraphs(text, segments, [{ startS: 20, endS: 20.5 }])).toBe(text);
    const input = text.replace(`${a} `, `${a.slice(0,-1)}, `);
    expect(applyPauseParagraphs(input, segments, pauses)).toBe(input);
  });
  test('abbreviations, ellipses, ambiguous anchors and existing paragraphs are preserved', () => {
    for (const ending of ['Dr.', 'fu…', 'wait...']) {
      const first = a.slice(0,-1) + ' ' + ending;
      const input = `${first} ${b} ${c}`;
      expect(applyPauseParagraphs(input, [{ ...segments[0], text: first }, ...segments.slice(1)], pauses)).toBe(input);
    }
    expect(applyPauseParagraphs(`${text} ${text}`, segments, pauses)).toBe(`${text} ${text}`);
    expect(applyPauseParagraphs(`${a}\n\n${b} ${c}`, segments, pauses)).toBe(`${a}\n\n${b} ${c}`);
  });
  test('absolute chunk times and closing quotes preserve punctuation and make the same break', () => {
    const input = text.replace(`${a} `, `${a}” `);
    expect(applyPauseParagraphs(input, segments.map(s=>({...s,startS:s.startS+90,endS:s.endS+90})), pauses.map(p=>({startS:p.startS+90,endS:p.endS+90})))).toBe(`${a}”\n\n${b} ${c}`);
  });
  test('ranks longest sentence-end pauses toward one break per 450 chars', () => {
    const parts = Array.from({length:7}, (_,i) => (`Section ${i} describes a different concern and preserves every spoken detail for section number ${i}. `.repeat(4)).trim());
    const lengths = [.7,3,1,2,4,.8];
    const evidence = parts.map((text,i)=>({text,startS:i*10,endS:i*10+5}));
    const stops = lengths.map((length,i)=>({startS:i*10+5,endS:i*10+5+length}));
    const input = parts.join(' ');
    const output = applyPauseParagraphs(input,evidence,stops);
    expect(output.split('\n\n').length-1).toBe(Math.round(input.length/450));
    expect(output).toContain(`${parts[4]}\n\n${parts[5]}`);
    expect(output.split('\n\n').every(p=>p.length>=200)).toBe(true);
  });
  test('unbound, stale or cancelled audio cannot supply paragraph timing', async () => {
    expect(await buildBoundaryContext('missing.wav', segments, undefined, {})).toBeUndefined();
    expect(await buildBoundaryContext('missing.wav', segments, 'digest', {}, AbortSignal.abort())).toBeUndefined();
    const path = `${TEST_TMP}/paragraph-audio.wav`;
    await Bun.write(path, new Uint8Array(44));
    expect(await buildBoundaryContext(path, segments, 'different-audio', {})).toBeUndefined();
  });
  test('processing settings use env > file > default and expose the socket toggle', () => {
    const env = { VOICELAYER_PROCESSING_SETTINGS_PATH: `${TEST_TMP}/paragraph-settings.json` };
    expect(pauseParagraphsEnabled(processingEnv(env))).toBe(true);
    setProcessingSetting('pause_paragraphs', false, env);
    expect(pauseParagraphsEnabled(processingEnv(env))).toBe(false);
    expect(pauseParagraphsEnabled(processingEnv({...env, VOICELAYER_STT_PAUSE_PARAGRAPHS:'yes'}))).toBe(true);
    expect(pauseParagraphsEnabled(processingEnv({...env, VOICELAYER_STT_PAUSE_PARAGRAPHS:''}))).toBe(true);
    expect(readPolishControlsStatus(env).pause_paragraphs).toEqual({source:'settings',raw:null,effective:false});
    expect(parseCommand('{"cmd":"set_processing_setting","key":"pause_paragraphs","value":false}')).toMatchObject({key:'pause_paragraphs',value:false});
  });
  test('paragraphs run after finalization even with model polish off or no surface', async () => {
    const env = { QA_VOICE_STT_POLISH:'off', VOICELAYER_STT_CORRECTIONS:'off' };
    for (const surface of ['dictation','voice_ask',null] as const) {
      const on = await finalizeTranscriptionResultForSurface(text, surface, env, {segments,pauses});
      const off = await finalizeTranscriptionResultForSurface(text, surface, {...env,VOICELAYER_STT_PAUSE_PARAGRAPHS:'0'}, {segments,pauses});
      expect(on.text).toContain('\n\n');
      expect(off.text).not.toContain('\n\n');
      expect(on.text.replace(/\s/gu,'')).toBe(off.text.replace(/\s/gu,''));
    }
  });
});
