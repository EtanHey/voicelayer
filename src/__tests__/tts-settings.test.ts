import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import * as settings from "../tts-settings";
import { resolveSpeakProfile, setTTSSetting } from "../tts-settings";
import { readTTSControlsStatus, recordFirstAudio, probeCloneDaemon } from "../tts-controls-status";
import * as qwen from "../tts/qwen3";
import { buildHealthResponse } from "../daemon-health";
const dir = join(TEST_TMP, "tts-settings");
function env() { mkdirSync(dir, {recursive:true}); return { VOICELAYER_TTS_SETTINGS_PATH: join(dir,"settings.json"), HOME: dir }; }
afterEach(() => rmSync(dir,{recursive:true,force:true}));
test("missing file preserves defaults and auto selects long only above 400", () => {
  const e = env();
  expect(resolveSpeakProfile("short", "hello", e)).toMatchObject({kind:"short", engine:"edge",voice:"en-US-JennyNeural",rate:"+0%",rateSource:"default"});
  expect(resolveSpeakProfile("auto", "x".repeat(400),e).kind).toBe("short");
  expect(resolveSpeakProfile("auto", "x".repeat(401),e).kind).toBe("long");
});
test("atomic writes preserve independent fields and are reread", () => {
  const e = env(); setTTSSetting("short.voice","en-US-GuyNeural",e); setTTSSetting("long.rate","+20%",e); setTTSSetting("short_limit_chars",10,e);
  expect(resolveSpeakProfile("short","hello",e).voice).toBe("en-US-GuyNeural");
  expect(resolveSpeakProfile("auto","01234567890",e)).toMatchObject({kind:"long", rate:"+20%"});
  expect(JSON.parse(readFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"utf8"))).toMatchObject({version:1,profiles:{short:{voice:"en-US-GuyNeural"},long:{rate:"+20%"}}});
  expect(readdirSync(dir)).toEqual(["settings.json"]);
});
test("env wins even empty, locks both profiles, and retains historical empty fallback", () => {
  const e = env(); setTTSSetting("short.voice","en-US-GuyNeural",e); setTTSSetting("long.rate","+20%",e);
  const locked = {...e, QA_VOICE_TTS_VOICE:"",QA_VOICE_TTS_RATE:""};
  expect(resolveSpeakProfile("short","hello",locked).voice).toBe("en-US-JennyNeural");
  expect(resolveSpeakProfile("long","hello",locked).rate).toBe("+0%");
  expect(readTTSControlsStatus(locked).profiles.short.voice).toMatchObject({source:"environment",raw:"",effective:"en-US-JennyNeural",locked:"Set by QA_VOICE_TTS_VOICE"});
  expect(()=>setTTSSetting("long.rate","+10%",locked)).toThrow("QA_VOICE_TTS_RATE");
});
test("corrupt and invalid file fields default independently; setter validates", () => {
  const e=env(); writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"{bad");
  expect(resolveSpeakProfile("short","",e).rate).toBe("+0%");
  writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,JSON.stringify({profiles:{short:{engine:"bad",voice:42,rate:"oops"}},short_limit_chars:-1}));
  expect(resolveSpeakProfile("auto","x".repeat(401),e)).toMatchObject({engine:"edge",voice:"en-US-JennyNeural",rate:"+0%",kind:"long"});
  for (const [key,value] of [["short.engine","bad"],["short.rate","fast"],["short.voice",""],["short_limit_chars",0]]) expect(()=>setTTSSetting(key as never,value as never,e)).toThrow();
});
test("status lists presets and actual installed directories, with per-profile latency", () => {
  const e=env(); mkdirSync(join(dir,".voicelayer/voices/theo-c4"),{recursive:true});
  writeFileSync(join(dir,".voicelayer/voices/theo-c4/profile.yaml"),"name: Theo\n");
  writeFileSync(join(dir,".voicelayer/voices.json"),JSON.stringify({guy:{engine:"edge-tts",voice:"en-US-GuyNeural"}}));
  recordFirstAudio("long",123);
  const status=readTTSControlsStatus(e);
  expect(status.available_voices).toContainEqual({engine:"clone",voice:"theo-c4"});
  expect(status.available_voices).toContainEqual({engine:"edge",voice:"guy"});
  expect(status.available_voices.some(v=>v.voice==="theo-c4s")).toBe(false);
  expect(status.profiles.long.last_first_audio_ms).toBe(123);
});
test("clone health probe caches success and failure without synthesizing", async () => {
  await probeCloneDaemon();
  const auth = spyOn(qwen,"buildDaemonRequestHeaders").mockReturnValue({Authorization:"Bearer fixture"});
  try {
  let calls=0;
  const fetcher=(async (url: unknown)=>{expect(String(url)).toBe("http://127.0.0.1:8880/health"); calls++; return new Response(JSON.stringify({status:"ok",model_loaded:true}),{status:200});}) as typeof fetch;
  expect(await probeCloneDaemon(fetcher,Date.now()+10000)).toBe("up");
  expect(await probeCloneDaemon(fetcher,Date.now()+10001)).toBe("up"); expect(calls).toBe(1);
  expect(await probeCloneDaemon((async()=>{throw new Error("down");}) as typeof fetch,Date.now()+20000)).toBe("down");
  } finally { auth.mockRestore(); }
});

test("daemon health includes the passed environment's speech controls", () => {
 const e=env(); setTTSSetting("long.rate","+20%",e);
 const health=buildHealthResponse({queueDepth:0,recordingState:"idle",modelStatus:{} as never},{...e,QA_VOICE_TTS_VOICE:"en-US-AriaNeural"});
 expect(health.tts_controls.profiles.long.rate).toMatchObject({source:"settings",effective:"+20%"});
 expect(health.tts_controls.profiles.short.voice).toMatchObject({source:"environment",effective:"en-US-AriaNeural"});
});
test("legacy env-selected clone is reflected in the effective engine", () => {
 const profile=spyOn(qwen,"hasClonedProfile").mockReturnValue(true);
 try {
  const e={...env(),QA_VOICE_TTS_VOICE:"fixture"};
  expect(resolveSpeakProfile("short","hello",e).engine).toBe("clone");
  expect(readTTSControlsStatus(e).profiles.short.engine).toMatchObject({source:"environment",effective:"clone"});
 } finally {profile.mockRestore();}
});

test("R1 env voice overrides the saved engine in both directions, including empty", () => {
 const e=env(); const profile=spyOn(qwen,"hasClonedProfile").mockImplementation(v=>v==="fixture");
 try {
  writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture"}}}));
  for(const voice of ["en-US-JennyNeural",""]) expect(resolveSpeakProfile("short","hello",{...e,QA_VOICE_TTS_VOICE:voice})).toMatchObject({engine:"edge",engineSource:"environment",voice:"en-US-JennyNeural"});
  writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,JSON.stringify({profiles:{short:{engine:"edge",voice:"en-US-JennyNeural"}}}));
  expect(resolveSpeakProfile("short","hello",{...e,QA_VOICE_TTS_VOICE:"fixture"})).toMatchObject({engine:"clone",engineSource:"environment"});
 } finally {profile.mockRestore();}
});
test("R5 voice values are persisted trimmed", () => {
 const e=env(); setTTSSetting("short.voice","  en-US-GuyNeural  ",e);
 expect(JSON.parse(readFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"utf8")).profiles.short.voice).toBe("en-US-GuyNeural");
});
test("R4 inconsistent effective pairs are rejected without writing", () => {
 const e=env(); const profile=spyOn(qwen,"hasClonedProfile").mockReturnValue(false);
 try { expect(()=>setTTSSetting("short.engine","clone",e)).toThrow("engine/voice"); expect(()=>readFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"utf8")).toThrow(); }
 finally {profile.mockRestore();}
});
