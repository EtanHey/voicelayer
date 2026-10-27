import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, symlinkSync, lstatSync, statSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { resolveSpeakProfile, setTTSSetting, setTTSProfile } from "../tts-settings";
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
test("P3 catalog retains every fast voice and only accepted Theo; assets remain intact", () => {
  const e = env();
  const names = ["theo-c4s", "theo", "theo-c4", "theo-c3", "huberman", "ben-c1"];
  for (const name of names) {
    mkdirSync(join(dir, ".voicelayer/voices", name), {recursive:true});
    writeFileSync(join(dir, ".voicelayer/voices", name, "profile.yaml"), "name: fixture\n");
  }
  writeFileSync(join(dir, ".voicelayer/voices.json"), JSON.stringify({guy:{engine:"edge-tts",voice:"en-US-GuyNeural"},custom:{engine:"edge-tts",voice:"he-IL-AvriNeural"}}));
  recordFirstAudio("long",123);
  const status = readTTSControlsStatus(e);
  expect(status.profiles.long.last_first_audio_ms).toBe(123);
  const voices = status.available_voices;
  expect(voices.filter(v => v.engine === "clone")).toEqual([{engine:"clone",voice:"theo-c4s"}]);
  expect(voices.filter(v => v.engine === "edge").map(v => v.voice).sort()).toEqual([
    "en-US-GuyNeural", "en-US-JennyNeural", "en-US-AndrewNeural", "en-US-BrianMultilingualNeural",
    "en-US-AvaNeural", "en-US-AriaNeural", "guy", "custom",
  ].sort());
  expect(voices).toContainEqual({engine:"edge",voice:"custom"});
  expect(readdirSync(join(dir, ".voicelayer/voices")).sort()).toEqual(names.sort());
});
test("P3 legacy selections migrate on read, preserving rate, threshold and environment locks", () => {
  const e = env();
  mkdirSync(join(dir, ".voicelayer/voices/theo-c4s"), {recursive:true});
  writeFileSync(join(dir, ".voicelayer/voices/theo-c4s/profile.yaml"), "name: Theo\n");
  for (const voice of ["theo", "theo-c4", "theo-c3", "huberman", "ben-c1"]) {
    writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH, JSON.stringify({profiles:{short:{engine:"clone",voice,rate:"+20%"},long:{engine:"edge",voice:"en-US-GuyNeural"}},short_limit_chars:500}));
    expect(resolveSpeakProfile("short", "", e)).toMatchObject({engine:"clone",voice:"theo-c4s",rate:"+20%"});
    expect(resolveSpeakProfile("long", "", e)).toMatchObject({engine:"edge",voice:"en-US-GuyNeural"});
    expect(readTTSControlsStatus(e).short_limit_chars.effective).toBe(500);
    expect(resolveSpeakProfile("short", "", {...e,QA_VOICE_TTS_VOICE:voice}).voice).toBe(voice);
    setTTSSetting("short_limit_chars", 600, e);
    expect(JSON.parse(readFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"utf8")).profiles.short).toEqual({engine:"clone",voice:"theo-c4s",rate:"+20%"});
  }
});
test("P3 selected voice survives relaunch with one atomic pair and independent profiles", () => {
  const e = env();
  const profile = spyOn(qwen,"hasClonedProfile").mockImplementation(v => v === "theo-c4s");
  try {
    setTTSSetting("short.rate", "+20%", e);
    setTTSProfile("short", {engine:"clone",voice:"theo-c4s"}, e);
    setTTSProfile("long", {engine:"edge",voice:"en-US-GuyNeural"}, e);
    expect(resolveSpeakProfile("short", "", {...e})).toMatchObject({engine:"clone",voice:"theo-c4s",rate:"+20%"});
    expect(resolveSpeakProfile("long", "", {...e})).toMatchObject({engine:"edge",voice:"en-US-GuyNeural"});
  } finally { profile.mockRestore(); }
});
test.each([true, false])("clone health probe caches loaded=%s success and load failure without synthesizing", async (modelLoaded) => {
  await probeCloneDaemon();
  const auth = spyOn(qwen,"buildDaemonRequestHeaders").mockReturnValue({Authorization:"Bearer fixture"});
  try {
  let calls=0;
  const fetcher=(async (url: unknown)=>{expect(String(url)).toBe("http://127.0.0.1:8880/health"); calls++; return new Response(JSON.stringify({status:"ok",model_loaded:modelLoaded}),{status:200});}) as typeof fetch;
  expect(await probeCloneDaemon(fetcher,Date.now()+(modelLoaded ? 10000 : 40000))).toBe("up");
  expect(await probeCloneDaemon(fetcher,Date.now()+(modelLoaded ? 10001 : 40001))).toBe("up"); expect(calls).toBe(1);
  expect(await probeCloneDaemon((async()=>Response.json({status:"error",model_loaded:false})) as typeof fetch,Date.now()+(modelLoaded ? 15000 : 45000))).toBe("down");
  expect(await probeCloneDaemon((async()=>{throw new Error("down");}) as typeof fetch,Date.now()+(modelLoaded ? 20000 : 50000))).toBe("down");
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
test("R2 engine raw stays engine-valued under a voice env override", () => {
 const profile=spyOn(qwen,"hasClonedProfile").mockImplementation(v=>v==="fixture");
 try {
  for(const [voice,engine] of [["en-US-JennyNeural","edge"],["fixture","clone"],["","edge"]]) {
   const status=readTTSControlsStatus({...env(),QA_VOICE_TTS_VOICE:voice});
   for(const kind of ["short","long"] as const) expect(status.profiles[kind].engine).toEqual({source:"environment",raw:engine,effective:engine,locked:"Set by QA_VOICE_TTS_VOICE"});
  }
 } finally {profile.mockRestore();}
});


test("settings write never promotes a preexisting staging symlink", () => {
 const e = env();
 const substitute = join(dir, "substitute.json");
 const stale = `${e.VOICELAYER_TTS_SETTINGS_PATH}.${process.pid}.tmp`;
 writeFileSync(substitute, JSON.stringify({short_limit_chars:999}));
 symlinkSync(substitute, stale);
 setTTSSetting("short_limit_chars",123,e);
 expect(lstatSync(e.VOICELAYER_TTS_SETTINGS_PATH).isSymbolicLink()).toBe(false);
 expect(resolveSpeakProfile("auto","x".repeat(124),e).kind).toBe("long");
 expect(JSON.parse(readFileSync(substitute,"utf8"))).toEqual({short_limit_chars:999});
 expect(lstatSync(stale).isSymbolicLink()).toBe(true);
 expect(statSync(e.VOICELAYER_TTS_SETTINGS_PATH).mode & 0o777).toBe(0o600);
 expect(readdirSync(dir).sort()).toEqual(["settings.json", `settings.json.${process.pid}.tmp`, "substitute.json"].sort());
});

test("failed settings rename removes only its own staging directory", () => {
 const e = env();
 mkdirSync(e.VOICELAYER_TTS_SETTINGS_PATH);
 writeFileSync(join(e.VOICELAYER_TTS_SETTINGS_PATH,"keep"),"original");
 expect(()=>setTTSSetting("short_limit_chars",123,e)).toThrow();
 expect(readFileSync(join(e.VOICELAYER_TTS_SETTINGS_PATH,"keep"),"utf8")).toBe("original");
 expect(readdirSync(dir)).toEqual(["settings.json"]);
});

test("P3 unavailable migration falls back without changing private files or locked choices", () => {
  const e = env();
  const original = JSON.stringify({profiles:{short:{engine:"clone",voice:"theo-c4",rate:"-10%"}}});
  writeFileSync(e.VOICELAYER_TTS_SETTINGS_PATH, original);
  expect(resolveSpeakProfile("short", "", e)).toMatchObject({engine:"edge",voice:"en-US-JennyNeural",rate:"-10%"});
  expect(readFileSync(e.VOICELAYER_TTS_SETTINGS_PATH,"utf8")).toBe(original);
  expect(readTTSControlsStatus(e).available_voices.filter(v => v.engine === "clone")).toEqual([]);
});
