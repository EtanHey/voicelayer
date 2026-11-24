import { expect, test, spyOn } from 'bun:test';
import { buildPolishSystemPrompt, polishTranscriptionText } from '../stt-polish';
import { finalizeTranscriptionResultForSurface } from '../input';
import { readFileSync, existsSync } from 'node:fs';
import { loadPolishPairsFromJsonl } from '../stt-quality-mining';
import { testTmp } from './setup/test-tmp';

test('formatting instructions carry no copyable few-shot responses', () => {
  for (const retry of [undefined, 'noop', 'rejected'] as const) {
    expect(buildPolishSystemPrompt(retry)).not.toMatch(/(?:Input|Output):/);
  }
});

test('rejected candidates stay in the local mining log but not stderr or archive reason', async () => {
  const candidate = 'Keep every word secretModelIdentifier.';
  const logPath = testTmp('polish-safe-rejected.jsonl');
  const stderr = spyOn(console, 'error').mockImplementation(() => {});
  const server = Bun.serve({ port: 0, fetch: request => request.method === 'GET'
    ? Response.json({ data: [] })
    : Response.json({ choices: [{ message: { content: candidate } }] }),
  });
  try {
    const result = await finalizeTranscriptionResultForSurface('keep every word', 'dictation', {
      QA_VOICE_STT_POLISH: 'on',
      QA_VOICE_STT_CORRECTIONS: 'off',
      QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      QA_VOICE_STT_POLISH_LOG_PATH: logPath,
    });
    for (let i = 0; i < 100 && !existsSync(logPath); i++) await Bun.sleep(5);
    const row = JSON.parse(readFileSync(logPath, 'utf8').trim());
    expect(row.status).toBe('rejected');
    expect(row.polished_text).toBe(candidate);
    expect(loadPolishPairsFromJsonl(logPath)).toMatchObject([{ status: 'rejected', polishedText: candidate }]);
    expect(row.reason).toBe('polish response invented code identifier');
    expect(result.polishStatus).toBe('rejected');
    // This is the reason the input finalizer passes to archive/socket metadata.
    expect(result.polishReason).toBe(row.reason);
    expect(result.polishReason).not.toContain('secretModelIdentifier');
    const rejectionLines = stderr.mock.calls.map(args => args.join(' ')).filter(line => line.includes('polish_rejected'));
    expect(rejectionLines).toHaveLength(1);
    expect(rejectionLines[0]).toContain(row.reason);
    expect(rejectionLines[0]).not.toContain('secretModelIdentifier');
  } finally {
    server.stop(true);
    stderr.mockRestore();
  }
});

test('comma filler formatting preserves So um I think uh through the validator', async () => {
  const candidate = 'So, um, I think, uh, we should ship it.';
  const server = Bun.serve({ port: 0, fetch: request => request.method === 'GET'
    ? Response.json({ data: [] })
    : Response.json({ choices: [{ message: { content: candidate } }] }),
  });
  try {
    const result = await polishTranscriptionText({ rawText: 'So um I think uh we should ship it.', cleanedText: 'So um I think uh we should ship it.', env: {
      QA_VOICE_STT_POLISH: 'on',
      QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      QA_VOICE_STT_POLISH_LOG_PATH: testTmp('polish-safe-fillers.jsonl'),
    } });
    expect(result.status).toBe('applied');
    expect(result.text).toBe(candidate);
  } finally { server.stop(true); }
});
