import { expect, spyOn, test } from "bun:test";
import { existsSync, readFileSync, statSync, watch, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { startTranscriptionsHttp, startTranscriptionsHttpIfEnabled, transcriptionsSecretPath, MAX_TRANSCRIPTION_BYTES } from "../transcriptions-http";
import { getTmpRoot } from "../paths";
import { reserveStandardVoiceOperation, hasActiveVoiceOperation } from "../voice-operation-reservation";
import * as jobs from "../recording-jobs";
import { setRecordingState } from "../recording-state";
import { privateCorpusPaths } from "./setup/private-specimens";
import { loadSpeechSecret } from "../speech-control";
import { processingSettingsPath, setProcessingSetting } from "../processing-settings";
import { ParakeetServer } from "../parakeet-server";
import { getBackend, shutdownSTTBackends, buildWhisperServerOptions, type STTBackend } from "../stt";

const corpus = privateCorpusPaths("transcriptions-http");
const fixture = join(import.meta.dir, "fixtures/golden-punctuation.wav");
const raw = JSON.parse(readFileSync(join(import.meta.dir, "fixtures/golden-punctuation.decoder.json"), "utf8")).text as string;
const result = { text: raw, backend: "recorded-decoder", durationMs: 0 };
const metadata = (audio: string) => JSON.parse(readFileSync(join(dirname(audio), "metadata.json"), "utf8"));
function upload(bytes = readFileSync(fixture), format = "json") {
  const form = new FormData();
  for (const [key, value] of Object.entries({ model: "any-client-model", language: "en", prompt: "developer vocabulary", "languages[]": "en", "keywords[]": "ignored", response_format: format })) form.set(key, value);
  form.set("file", new Blob([bytes], { type: "audio/wav" }), "clip.wav");
  return form;
}
const serve = (decode: STTBackend["transcribe"], extra = {}) => startTranscriptionsHttp({ port: 0, canLoad: () => true, decode, ...extra });
const headers = () => ({ Authorization: `Bearer ${readFileSync(transcriptionsSecretPath(), "utf8")}` });
const post = (server: ReturnType<typeof serve>, body = upload(), signal?: AbortSignal) => fetch(`http://127.0.0.1:${server.port}/v1/audio/transcriptions`, { method: "POST", headers: headers(), body, signal });

test.each(["en", "he", "auto"])("client language %s cannot override VoiceLayer's bilingual setting", async language => {
  const old = process.env.QA_VOICE_WHISPER_LANG, seen: unknown[] = [];
  process.env.QA_VOICE_WHISPER_LANG = "auto";
  const server = serve(async (_, options) => { seen.push(buildWhisperServerOptions(options)?.language); return result; });
  try { const form = upload(); form.set("language", language); expect((await post(server, form)).status).toBe(200); expect(seen).toEqual(["auto"]); }
  finally { server.stop(true); if (old === undefined) delete process.env.QA_VOICE_WHISPER_LANG; else process.env.QA_VOICE_WHISPER_LANG = old; }
});

test("real route applies dictionary, retains WAV/History, authenticates and never delivers/logs", async () => {
  const old = { ...process.env }, delivery = spyOn(jobs, "deliverInputTranscription");
  let calls = 0, audio = ""; const languages: unknown[] = [];
  const server = serve(async (path, options) => {
    calls++; audio = path;
    expect(readFileSync(path)).toEqual(readFileSync(fixture));
    languages.push(options?.language); expect(options?.promptOverride).toBe("developer vocabulary");
    expect(hasActiveVoiceOperation()).toBe(true);
    return result;
  });
  try {
    process.env.QA_VOICE_STT_POLISH = "off"; process.env.QA_VOICE_CORRECTOR = "off";
    process.env.QA_VOICE_STT_POLISH_LOG_PATH = join(getTmpRoot(), "http-log.jsonl");
    writeFileSync(process.env.QA_VOICE_STT_POLISH_LOG_PATH, "existing\n");
    writeFileSync(process.env.QA_VOICE_STT_VOCABULARY_PATH!, JSON.stringify({ version: 1, entries: [{ canonical: "RegressionFixture", variants: ["bug"] }] }));
    const token = readFileSync(transcriptionsSecretPath(), "utf8");
    expect(statSync(transcriptionsSecretPath()).mode & 0o777).toBe(0o600);
    for (const value of ["", "Bearer wrong", `Bearer ${loadSpeechSecret()}`]) {
      expect((await fetch(`http://127.0.0.1:${server.port}/v1/audio/transcriptions`, { method: "POST", headers: { Authorization: value }, body: upload() })).status).toBe(401);
    }
    expect(calls).toBe(0);
    for (const format of ["json", "text"]) {
      const response = await post(server, upload(undefined, format));
      expect(response.status).toBe(200);
      expect(format === "json" ? (await response.json()).text : await response.text()).toBe("I fixed the RegressionFixture. Did it work?");
    }
    expect(languages).toEqual([undefined, undefined]);
    expect(metadata(audio).upload_source).toBe("t3"); expect(metadata(audio).transcription_status).toBe("transcribed");
    expect(readFileSync(join(dirname(audio), "voicelayer-transcript.txt"), "utf8")).toBe("I fixed the RegressionFixture. Did it work?");
    for (const state of ["recording", "transcribing"] as const) {
      setRecordingState(state);
      try { expect((await post(server)).status).toBe(409); } finally { setRecordingState("idle"); }
    }
    for (const [bytes, status] of [[Buffer.from("RIFFbroken"), 400], [Buffer.alloc(MAX_TRANSCRIPTION_BYTES + 1), 413]] as const) expect((await post(server, upload(bytes))).status).toBe(status);
    expect(calls).toBe(2); expect(delivery).not.toHaveBeenCalled();
    const polish = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("", { status: 500 }) });
    try {
      process.env.QA_VOICE_STT_POLISH = "on"; process.env.QA_VOICE_STT_POLISH_ENDPOINT = `http://127.0.0.1:${polish.port}/v1/chat/completions`;
      expect((await post(server)).status).toBe(200); expect(metadata(audio).provenance.polish_status).toBe("failed"); expect(hasActiveVoiceOperation()).toBe(false);
    } finally { polish.stop(true); }

    expect(readFileSync(process.env.QA_VOICE_STT_POLISH_LOG_PATH, "utf8")).toBe("existing\n");
    const restart = serve(async () => result);
    try { expect(readFileSync(transcriptionsSecretPath(), "utf8")).toBe(token); } finally { restart.stop(true); }
  } finally { server.stop(true); delivery.mockRestore(); process.env = old; }
});

test("exclusive reservation blocks overlapping upload/live capture, then releases after decode failure", async () => {
  const started = Promise.withResolvers<void>(), decoder = Promise.withResolvers<never>();
  let audio = "";
  const server = serve(async path => { audio = path; started.resolve(); return decoder.promise; });
  const pending = post(server);
  try {
    await started.promise;
    expect(jobs.canStartBarCapture()).toBe(false); expect(reserveStandardVoiceOperation()).toBeNull();
    expect((await post(server)).status).toBe(409);
    decoder.reject(new Error("private decoder details"));
    const failed = await pending;
    expect(failed.status).toBe(503); expect(await failed.text()).not.toContain("private decoder details");
    expect(existsSync(audio)).toBe(true); expect(metadata(audio).not_transcribed_reason).toBe("api-failed");
    expect(hasActiveVoiceOperation()).toBe(false); expect(jobs.canStartBarCapture()).toBe(true);
  } finally { decoder.reject(new Error("cleanup")); await pending; server.stop(true); }
});

for (const [reason, polishing] of [["aborted", false], ["timeout", false], ["aborted", true]] as const) test(`${reason} during ${polishing ? "polish" : "decode"} saves receipt and permits retry`, async () => {
  const old = { ...process.env };
  const polishGate = Promise.withResolvers<Response>();
  const polish = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: req => {
    if (req.method === "GET" || calls > 1) return Response.json({ choices: [{ message: { content: raw } }] });
    started.resolve(); return polishGate.promise;
  } });
  process.env.QA_VOICE_STT_POLISH = polishing ? "on" : "off";
  process.env.QA_VOICE_STT_POLISH_ENDPOINT = `http://127.0.0.1:${polish.port}/v1/chat/completions`;
  process.env.QA_VOICE_CORRECTOR = "identity";
  const started = Promise.withResolvers<void>(), decoder = Promise.withResolvers<typeof result>();
  const client = new AbortController(), deadline = new AbortController();
  let signal: AbortSignal | undefined, audio = "", calls = 0;
  const server = serve(async (path, options) => {
    if (calls++) return result;
    audio = path; signal = options?.signal; if (polishing) return result; started.resolve();
    signal?.addEventListener("abort", () => decoder.reject(signal!.reason), { once: true });
    return decoder.promise;
  }, { deadlineSignal: () => calls === 0 ? deadline.signal : undefined });
  const pending = post(server, upload(), client.signal).catch(() => null);
  let watcher: ReturnType<typeof watch> | undefined;
  try {
    await started.promise; expect(signal).toBeInstanceOf(AbortSignal);
    const receipt = new Promise<void>(resolve => { watcher = watch(dirname(audio), (_, name) => {
      if (name === "metadata.json" && metadata(audio).not_transcribed_reason === `api-${reason}`) resolve();
    }); });
    if (reason === "aborted") client.abort(); else deadline.abort(new DOMException("deadline", "TimeoutError"));
    const response = await pending;
    if (reason === "timeout") expect(response?.status).toBe(503);
    await receipt;
    expect(hasActiveVoiceOperation()).toBe(false);
    expect((await post(server)).status).toBe(200);
  } finally { watcher?.close(); decoder.resolve(result); polishGate.resolve(Response.json({})); await pending; server.stop(true); polish.stop(true); process.env = old; }
});

for (const timeout of [false, true]) test(`cold owner loads once; timeout=${timeout} preserves its loading child`, async () => {
  const started = Promise.withResolvers<void>(), gate = Promise.withResolvers<Response>();
  const control = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => { started.resolve(); return gate.promise.then(() => new Response("ready")); } });
  const child = join(getTmpRoot(), `cold-child-${timeout}.mjs`), deadline = new AbortController();
  writeFileSync(child, `import { createInterface } from 'node:readline';
for await (const line of createInterface({input:process.stdin})) {
 const r=JSON.parse(line); if(r.op==='health') await fetch('http://127.0.0.1:${control.port}');
 console.log(JSON.stringify({id:r.id,ok:true,ready:true,protocol:1,pid:process.pid,text:${JSON.stringify(raw)},complete:true,input_frames:16000,covered_frames:16000,sample_rate:16000,last_token_end_s:1,inference_s:0.01,language:null}));
}`);
  let loads = 0, audio = "";
  const owner = new ParakeetServer({ command: [process.execPath, child], isBusy: () => false, onState: phase => { if (phase === "loading") loads++; } });
  const server = startTranscriptionsHttp({ port: 0, canLoad: () => true, deadlineSignal: () => deadline.signal,
    decode: async (path, options) => { audio = path; return { ...result, ...await owner.transcribe(path, options?.signal) }; } });
  try {
    expect(await owner.health()).toBe(false);
    const pending = post(server); await Promise.race([started.promise, pending.then(r => expect(r.status).toBe(200))]); const pid = owner.pid;
    if (timeout) {
      deadline.abort(new DOMException("deadline", "TimeoutError"));
      expect((await pending).status).toBe(503); expect(owner.pid).toBe(pid);
      expect(metadata(audio).not_transcribed_reason).toBe("api-timeout"); expect(hasActiveVoiceOperation()).toBe(false);
    }
    gate.resolve(new Response("ready"));
    if (!timeout) expect((await pending).status).toBe(200);
    await owner.health();
    if (timeout) { const retry = serve(async (path, options) => ({ ...result, ...await owner.transcribe(path, options?.signal) }));
      try { expect((await post(retry)).status).toBe(200); } finally { retry.stop(true); } }
    expect(loads).toBe(1); expect(owner.pid).toBe(pid);
  } finally { gate.resolve(new Response("ready")); server.stop(true); await owner.shutdown(); control.stop(true); }
});

test("archive failure never decodes and releases admission for a subsequent request", async () => {
  const old = process.env.QA_VOICE_RECORDINGS_DIR;
  const blocker = join(getTmpRoot(), "archive-blocker"); writeFileSync(blocker, "not a directory");
  let calls = 0;
  const server = serve(async () => { calls++; return result; });
  try {
    process.env.QA_VOICE_RECORDINGS_DIR = blocker;
    expect((await post(server)).status).toBe(503); expect(calls).toBe(0); expect(hasActiveVoiceOperation()).toBe(false);
    process.env.QA_VOICE_RECORDINGS_DIR = old;
    expect((await post(server)).status).toBe(200);
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = old; server.stop(true); }
});

test("HTTP is opt-in; invalid bind cannot throw through daemon startup", () => {
  const old = { ...process.env };
  try {
    delete process.env.VOICELAYER_TRANSCRIPTIONS_ENABLED; expect(startTranscriptionsHttpIfEnabled()).toBeNull();
    process.env.VOICELAYER_TRANSCRIPTIONS_ENABLED = "1"; process.env.VOICELAYER_TRANSCRIPTIONS_HOST = "0.0.0.0";
    expect(startTranscriptionsHttpIfEnabled()).toBeNull();
    expect(() => startTranscriptionsHttp({ hostname: "0.0.0.0" })).toThrow("127.0.0.1");
    expect(() => startTranscriptionsHttp({ hostname: "127.0.0.1", port: -1 })).toThrow("port");
  } finally { process.env = old; }
});

test("saved enable survives restart and processing edits; explicit env wins", () => {
  const old = { ...process.env };
  try {
    process.env.VOICELAYER_PROCESSING_SETTINGS_PATH = join(getTmpRoot(), "http-settings.json");
    delete process.env.VOICELAYER_TRANSCRIPTIONS_ENABLED;
    expect(startTranscriptionsHttpIfEnabled({ port: 0 })).toBeNull();
    writeFileSync(processingSettingsPath(), JSON.stringify({ version: 1, transcriptions_enabled: true }));
    setProcessingSetting("outro_gate", false);
    for (let restart = 0; restart < 2; restart++) { const server = startTranscriptionsHttpIfEnabled({ port: 0 }); expect(server).not.toBeNull(); server?.stop(true); }
    process.env.VOICELAYER_TRANSCRIPTIONS_ENABLED = "0"; expect(startTranscriptionsHttpIfEnabled({ port: 0 })).toBeNull();
    writeFileSync(processingSettingsPath(), JSON.stringify({ version: 1, transcriptions_enabled: false }));
    process.env.VOICELAYER_TRANSCRIPTIONS_ENABLED = "1";
    const server = startTranscriptionsHttpIfEnabled({ port: 0 }); expect(server).not.toBeNull(); server?.stop(true);
  } finally { process.env = old; }
});

if (corpus && process.env.QA_VOICE_GOLDEN_LIVE === "1") test("native archived WAV runs through real decoder and finalizer", async () => {
  const old = { ...process.env }; let audio = "";
  const server = serve(async (path, options) => { audio = path; return (await getBackend()).transcribe(path, options); });
  try {
    process.env.QA_VOICE_STT_POLISH = "off";
    const response = await post(server, upload(readFileSync(join(corpus.recordings, "audio.wav"))));
    expect(response.status).toBe(200);
    const { text } = await response.json();
    expect(text.length).toBeGreaterThan(0); expect(text.trim()).toMatch(/[.!?]["')\]]?$/u);
    expect(metadata(audio).backend).toBe("whisper.cpp");
    expect(readFileSync(join(dirname(audio), "voicelayer-transcript.txt"), "utf8")).toBe(text);
  } finally { server.stop(true); await shutdownSTTBackends(); process.env = old; }
});
