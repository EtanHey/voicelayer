import { expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { archiveVoiceBarUntranscribedRecording, createWavBuffer, finalizeTranscriptionResultForSurface } from "../input";
import { transcriptionStageReceiptDirectory } from "../transcription-stage-receipt";

test("L7 retains private raw, rules and final stages per attempt without changing audio", async () => {
  const path = archiveVoiceBarUntranscribedRecording({ audioBytes: createWavBuffer(new Uint8Array(3200)), source: "voicebar", silenceMode: "standard", pushToEnd: false, durationMs: 100, backend: "fixture", reason: "captured" });
  const audio = join(path, "audio.wav"), bytes = readFileSync(audio);
  const raw = "Keep keep fu… no wait keep both versions.";
  for (let attempt = 0; attempt < 2; attempt++) {
    await finalizeTranscriptionResultForSurface(raw, "dictation", { ...process.env, QA_VOICE_STT_POLISH: "off", QA_VOICE_CORRECTOR: "identity" }, undefined, audio);
  }
  const directory = transcriptionStageReceiptDirectory(audio);
  const files = readdirSync(directory).filter(name => name.startsWith("stt-stages-"));
  expect(files).toHaveLength(2);
  for (const file of files) {
    const data = JSON.parse(readFileSync(join(directory, file), "utf8"));
    expect(statSync(join(directory, file)).mode & 0o777).toBe(0o600);
    expect(data.stages.raw).toBe(raw);
    expect(data.stages.after_rules).toBe(raw);
    expect(data.stages.after_polish).toBe(raw);
    expect(data.stages.delivered).toBe(raw);
    expect(data.polish_status).toBe("skipped");
    expect(data.complete).toBe(true);
    expect(data.audio_sha256).toMatch(/^[a-f0-9]{64}$/u);
  }
  expect(readFileSync(audio)).toEqual(bytes);
  expect(readFileSync(join(path, "metadata.json"), "utf8")).not.toContain(raw);
});

test("L7 seals raw and rules before waiting for polish", async () => {
  const path = archiveVoiceBarUntranscribedRecording({ audioBytes: createWavBuffer(new Uint8Array(3200)), source: "voicebar", silenceMode: "standard", pushToEnd: false, durationMs: 100, backend: "fixture", reason: "captured" });
  let resolvePost!: (response: Response) => void;
  let requestSeen!: () => void;
  const seen = new Promise<void>(resolve => { requestSeen = resolve; });
  const server = Bun.serve({port: 0, fetch(request) {
    if(request.method !== "POST") return Response.json({data: []});
    requestSeen();
    return new Promise<Response>(resolve => { resolvePost = resolve; });
  }});
  const raw = "Keep keep fu… no wait keep both versions.";
  try {
    const pending = finalizeTranscriptionResultForSurface(raw, "dictation", { ...process.env, QA_VOICE_CORRECTOR: "identity", QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions` }, undefined, join(path, "audio.wav"));
    await seen;
    const directory = transcriptionStageReceiptDirectory(join(path, "audio.wav"));
    const name = readdirSync(directory).find(name => name.startsWith("stt-stages-"));
    const before = name ? JSON.parse(readFileSync(join(directory, name), "utf8")) : null;
    resolvePost(Response.json({choices: [{message: {content: raw}}]}));
    await pending;
    expect(before).toMatchObject({complete: false, stages: {raw, after_rules: raw, after_polish: null, delivered: null}});
  } finally { server.stop(true); }
});
