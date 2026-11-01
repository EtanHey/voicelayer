import { test, expect, beforeEach } from "bun:test";
import { mkdirSync, writeFileSync, readFileSync } from "fs";
import { createHash } from "crypto";
import { testTmp } from "./setup/test-tmp";
import { ParakeetBackend } from "../parakeet-backend";
import { PARAKEET_EMPTY_SPEECH_THRESHOLD, type ParakeetSpeechEvidence } from "../parakeet-vad";
const path = testTmp("parakeet-vad", "speech.wav");
beforeEach(() => {
  mkdirSync(testTmp("parakeet-vad"), { recursive: true });
  const b = Buffer.alloc(32044); b.write("RIFF"); b.writeUInt32LE(32036, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write("data", 36); b.writeUInt32LE(32000, 40);
  for (let i = 44; i < b.length; i += 2) b.writeInt16LE(1, i); // quiet/nonzero is NOT an energy-silence oracle
  writeFileSync(path, b);
});
function setup(modify: (e: ParakeetSpeechEvidence) => void = () => {}) {
  let w = 0, vad = 0, unload = 0; const retained: any[] = [];
  const backend = new ParakeetBackend({
    env: () => ({ QA_VOICE_WHISPER_LANG: "en" }),
    transcribe: async () => ({ text: "", complete: true, input_frames: 16000, covered_frames: 16000, sample_rate: 16000, last_token_end_s: null, inference_s: 0, language: null }),
    speechProbe: async p => { vad++; const e: ParakeetSpeechEvidence = { status: "COMPLETE", threshold: 0.3, inputSha256: createHash("sha256").update(readFileSync(p)).digest("hex"), frames: 16000, analyzedFrames: 16000, speechFrames: 0, maxProbability: 0.1 }; modify(e); return e; },
    unload: async () => { unload++; },
    fallbackBackend: { name: "W-fixture", isAvailable: async () => true, transcribe: async () => { w++; return { text: "Quiet speech remains.", backend: "W-fixture", durationMs: 1 }; } },
    retainFallback: a => { retained.push(a); return "private-fixture-" + retained.length; },
  });
  return { backend, retained, counts: () => ({ w, vad, unload }) };
}
test("valid P empty + full low-speech VAD delivers empty without W or unloading P", async () => {
  expect(PARAKEET_EMPTY_SPEECH_THRESHOLD).toBe(0.3);
  const s = setup(); const r = await s.backend.transcribe(path);
  expect(r.text).toBe(""); expect(r.outcome).toBe("VAD_NO_SPEECH"); expect(s.counts()).toEqual({ w: 0, vad: 1, unload: 0 });
  expect(s.retained).toHaveLength(2);
  expect(s.retained[0]).toMatchObject({ parakeet: { text: "" }, stage: "native-or-input-boundary" });
  expect(s.retained[1]).toMatchObject({ whisper: null, whisperStatus: "NOT_RUN", speechEvidence: { speechFrames: 0 }, outcome: "VAD_NO_SPEECH" });
});
test("P empty with real-speech classification retries W even for extremely quiet PCM", async () => {
  const s = setup(e => { e.speechFrames = 512; e.maxProbability = 0.8; });
  expect((await s.backend.transcribe(path)).outcome).toBe("FALLBACK_NONEMPTY_COMPLETENESS_UNKNOWN");
  expect(s.counts()).toEqual({ w: 1, vad: 1, unload: 1 });
});
const controls: Record<string, (e: ParakeetSpeechEvidence) => void> = {
  unknown: e => { e.status = "UNKNOWN"; }, partial: e => { e.analyzedFrames = 512; }, wrong_audio: e => { e.inputSha256 = "wrong"; },
  invalid_timebase: e => { e.frames = 8000; }, invalid_probability: e => { e.maxProbability = NaN; }, wrong_threshold: e => { e.threshold = 0.9; }, boundary: e => { e.maxProbability = 0.3; },
};
for (const [name, mutate] of Object.entries(controls)) test(`VAD ${name} cannot suppress the Whisper retry`, async () => {
  const s = setup(mutate); expect((await s.backend.transcribe(path)).text).toBe("Quiet speech remains."); expect(s.counts().w).toBe(1);
});

test("completed raw VAD is durable before a pending Whisper retry", async () => {
  const started=Promise.withResolvers<void>(),finish=Promise.withResolvers<any>(),records:any[]=[];
  const b=new ParakeetBackend({env:()=>({QA_VOICE_WHISPER_LANG:"en"}),
    transcribe:async()=>({text:"",complete:true,input_frames:16000,covered_frames:16000,sample_rate:16000,last_token_end_s:null,inference_s:0,language:null}),
    speechProbe:async p=>({status:"COMPLETE",threshold:0.3,inputSha256:createHash("sha256").update(readFileSync(p)).digest("hex"),frames:16000,analyzedFrames:16000,speechFrames:512,maxProbability:0.8,probabilities:[0.8]}),
    unload:async()=>{},retainFallback:a=>{records.push(a);return "event-"+records.length;},
    fallbackBackend:{name:"W",isAvailable:async()=>true,transcribe:async()=>{started.resolve();return finish.promise;}}});
  const pending=b.transcribe(path);await started.promise;
  try {expect(records).toHaveLength(2);expect(records[1]).toMatchObject({stage:"vad-boundary",previousAttemptPath:"event-1",speechEvidence:{probabilities:[0.8]},whisper:null});}
  finally {finish.resolve({text:"Speech retained.",backend:"W",durationMs:1});await pending;}
});
