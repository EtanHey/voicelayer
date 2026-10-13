import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { speak, awaitCurrentPlayback, stopPlayback, VoiceProfileUnavailableError } from "../tts";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import * as qwen from "../tts/qwen3";
import * as xtts from "../tts/xtts";
import * as f5 from "../tts/f5tts";
import { readTTSControlsStatus } from "../tts-controls-status";
const dir=join(TEST_TMP,"tts-wiring");
let saved: Record<string,string|undefined>;
let spies: Array<ReturnType<typeof spyOn>>=[];
let argv: string[][]=[];
beforeEach(()=>{
 mkdirSync(dir,{recursive:true}); argv=[];
 saved=Object.fromEntries(["VOICELAYER_TTS_SETTINGS_PATH","QA_VOICE_TTS_VOICE","QA_VOICE_TTS_RATE","QA_VOICE_TTS_REQUIRE_CLONE"].map(k=>[k,process.env[k]]));
 process.env.VOICELAYER_TTS_SETTINGS_PATH=join(dir,"settings.json"); delete process.env.QA_VOICE_TTS_VOICE; delete process.env.QA_VOICE_TTS_RATE; delete process.env.QA_VOICE_TTS_REQUIRE_CLONE;
 spies.push(spyOn(recording,"getEffectiveRecordingState").mockReturnValue("idle"),spyOn(socket,"broadcast").mockImplementation(()=>{}));
 spies.push(spyOn(Bun,"spawn").mockImplementation(((cmd: string[])=>{
   argv.push([...cmd]);
   const media=cmd.find(a=>a.startsWith("--write-media="))?.split("=").slice(1).join("=");
   if(media) writeFileSync(media,"fake mp3");
   return {pid:98765,exited:Promise.resolve(0),stdout:new Blob([new Uint8Array([0,0])]).stream(),kill:()=>{}};
 }) as never));
 spies.push(spyOn(Bun,"spawnSync").mockImplementation(((cmd: string[])=>{argv.push([...cmd]); if(cmd[0]==="ffmpeg" && cmd.includes("-af")) writeFileSync(cmd.at(-1)!,"rate adjusted"); return {exitCode:0,stdout:Buffer.from("1.0"),stderr:Buffer.alloc(0)};}) as never));
});
afterEach(async()=>{stopPlayback(); await awaitCurrentPlayback(); for(const s of spies.splice(0))s.mockRestore(); for(const [k,v]of Object.entries(saved)) {if(v===undefined)delete process.env[k];else process.env[k]=v;} rmSync(dir,{recursive:true,force:true});});
function synthArgs(){return argv.filter(a=>a.some(x=>x.startsWith("--voice="))).map(a=>a.filter(x=>x.startsWith("--voice=")||x.startsWith("--rate=")));}
// Literal legacy argv oracle: mode rates and all three slowdown bands, captured independently of the resolver.
const goldenCases: Array<[number, string | undefined, string, number]> = [
 [5,undefined,"+0%",1],
 [5,"announce","+10%",1],[5,"brief","-10%",1],[5,"consult","+5%",1],[5,"converse","+0%",1],
 [350,"announce","+5%",1],[350,"brief","-15%",1],[350,"consult","+0%",1],[350,"converse","-5%",1],
 [650,"announce","+0%",2],[650,"brief","-20%",2],[650,"consult","-5%",2],[650,"converse","-10%",2],
 [1100,"announce","-5%",3],[1100,"brief","-25%",3],[1100,"consult","-10%",3],[1100,"converse","-15%",3],
];
test("R3 golden matrix covers all four modes and every slowdown band",()=>{
 expect([...new Set(goldenCases.map(([,mode])=>mode).filter(Boolean))].sort()).toEqual(["announce","brief","consult","converse"]);
 for(const minimum of [300,600,1000]) expect(goldenCases.some(([length])=>length>=minimum && length<(minimum===300?600:minimum===600?1000:Infinity))).toBe(true);
});
test("unset settings preserve byte-identical legacy voice/rate argv across modes and lengths",async()=>{
 for(const [length,mode,rate,chunks] of goldenCases) {
  argv=[];
  await speak("x".repeat(length),{mode}); await awaitCurrentPlayback();
  expect(synthArgs()).toEqual(Array.from({length:chunks},()=>["--voice=en-US-JennyNeural",`--rate=${rate}`]));
 }
 argv=[];
 await speak("hello",{rate:"+25%"});await awaitCurrentPlayback();
 expect(synthArgs()).toEqual([["--voice=en-US-JennyNeural","--rate=+25%"]]);
});
test("next speak rereads SHORT settings, explicit args win, env keeps mode precedence",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"edge",voice:"en-US-GuyNeural",rate:"+20%"},long:{voice:"en-US-AriaNeural"}}}));
 await speak("hello",{mode:"brief"}); await awaitCurrentPlayback();
 await speak("hello",{voice:"en-US-AndrewNeural",rate:"+30%"}); await awaitCurrentPlayback();
 process.env.QA_VOICE_TTS_RATE="+50%";
 await speak("hello",{mode:"brief"}); await awaitCurrentPlayback();
 expect(synthArgs()).toEqual([["--voice=en-US-GuyNeural","--rate=+20%"],["--voice=en-US-AndrewNeural","--rate=+30%"],["--voice=en-US-GuyNeural","--rate=-10%"]]);
});
test("configured clone uses cascade even for short announcements",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture",rate:"+0%"}}}));
 spies.push(spyOn(qwen,"loadProfile").mockReturnValue({name:"fixture",engine:"qwen3-tts"} as never),spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false));
 const synth=spyOn(qwen,"synthesizeCloned").mockResolvedValue(Buffer.from("audio"));spies.push(synth);
 const result=await speak("hello",{mode:"announce"});await awaitCurrentPlayback();
 expect(synth).toHaveBeenCalled(); expect(result.engine).toBe("qwen3-tts");
});

test("auto uses LONG, logs actual spawn latency once, and publishes it",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({short_limit_chars:10,profiles:{long:{engine:"edge",voice:"en-US-AriaNeural"}}}));
 const logs=spyOn(console,"error").mockImplementation(()=>{});spies.push(logs);
 let started: number|undefined;
 await speak("hello long reader",{profile:"auto",onPlaybackStart:t=>{started=t;}});await awaitCurrentPlayback();
 expect(synthArgs()[0]).toEqual(["--voice=en-US-AriaNeural","--rate=+0%"]);
 expect(started).toBeDefined();
 const lines=logs.mock.calls.filter(([line])=>String(line).startsWith("[tts] first_audio_ms="));
 expect(lines).toHaveLength(1);
 expect(String(lines[0][0])).toMatch(/profile=long engine=edge-tts voice=en-US-AriaNeural chars=17$/);
 const ms=Number(String(lines[0][0]).match(/first_audio_ms=(\d+)/)![1]);
 expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(ms);
});
test("explicit edge engine bypasses clone lookup; clone fallback logs actual edge engine",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"edge",voice:"en-US-GuyNeural"}}}));
 const profile=spyOn(qwen,"loadProfile").mockReturnValue({name:"fixture",engine:"qwen3-tts",fallback:"en-US-AriaNeural"} as never);spies.push(profile);
 await speak("hello");await awaitCurrentPlayback(); expect(profile).not.toHaveBeenCalled();
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture"}}}));
 spies.push(spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false),spyOn(qwen,"synthesizeCloned").mockResolvedValue(null));
 const logs=spyOn(console,"error").mockImplementation(()=>{});spies.push(logs);
 await speak("hello");await awaitCurrentPlayback();
 expect(logs.mock.calls.some(([line])=>String(line).includes("profile=short engine=edge-tts voice=en-US-AriaNeural"))).toBe(true);
});
test("clone rate adjusts audio before player spawn and explicit rate wins",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture",rate:"+20%"}}}));
 spies.push(spyOn(qwen,"loadProfile").mockReturnValue({name:"fixture",engine:"qwen3-tts"} as never),spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false),spyOn(qwen,"synthesizeCloned").mockResolvedValue(Buffer.from("audio")));
 await speak("hello",{rate:"+30%"});await awaitCurrentPlayback();
 expect(argv.find(a=>a.includes("-af"))).toContain("atempo=1.3");
 expect(argv.some(a=>a[0]==="afplay" && a.at(-1)?.endsWith(".rate.mp3"))).toBe(true);
});
test("explicit clone voice retains legacy announce shortcut over configured engine",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"edge",voice:"en-US-GuyNeural"}}}));
 spies.push(spyOn(qwen,"loadProfile").mockReturnValue({name:"fixture",engine:"qwen3-tts",fallback:"en-US-AriaNeural"} as never),spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false));
 const synth=spyOn(qwen,"synthesizeCloned").mockResolvedValue(Buffer.from("audio"));spies.push(synth);
 await speak("hello",{voice:"fixture",mode:"announce"});await awaitCurrentPlayback();
 expect(synth).not.toHaveBeenCalled();expect(synthArgs()[0]).toEqual(["--voice=en-US-AriaNeural","--rate=+10%"]);
});
test("env rate overrides saved clone rate",async()=>{
 writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture",rate:"+20%"}}}));
 process.env.QA_VOICE_TTS_RATE="+50%";
 spies.push(spyOn(qwen,"loadProfile").mockReturnValue({name:"fixture",engine:"qwen3-tts"} as never),spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false),spyOn(qwen,"synthesizeCloned").mockResolvedValue(Buffer.from("audio")));
 await speak("hello");await awaitCurrentPlayback();
 expect(argv.find(a=>a.includes("-af"))).toContain("atempo=1.5");
});

function cloneFixture(audio: Buffer | null = Buffer.from("audio")) {
 spies.push(spyOn(qwen,"hasClonedProfile").mockImplementation(v=>v==="fixture"),spyOn(qwen,"loadProfile").mockImplementation(v=>v==="fixture"?{name:"fixture",engine:"qwen3-tts",fallback:"en-US-AriaNeural"} as never:null),spyOn(xtts,"isXTTSAvailable").mockReturnValue(false),spyOn(f5,"isF5TTSAvailable").mockReturnValue(false),spyOn(qwen,"synthesizeCloned").mockResolvedValue(audio));
}
test("R1 file clone plus env edge or empty produces edge argv without throwing",async()=>{
 cloneFixture(); writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture"}}}));
 for(const voice of ["en-US-JennyNeural",""]) {process.env.QA_VOICE_TTS_VOICE=voice; await speak("hello");await awaitCurrentPlayback();}
 expect(synthArgs()).toEqual([["--voice=en-US-JennyNeural","--rate=+0%"],["--voice=en-US-JennyNeural","--rate=+0%"]]);
});
test("R1 env clone bypasses persisted edge engine",async()=>{
 cloneFixture();writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"edge",voice:"en-US-JennyNeural"}}}));
 process.env.QA_VOICE_TTS_VOICE="fixture";
 expect((await speak("hello",{mode:"brief"})).engine).toBe("qwen3-tts");await awaitCurrentPlayback();
});
test("R2 env clone rate never replaces edge announce mode on the shortcut",async()=>{
 cloneFixture();process.env.QA_VOICE_TTS_VOICE="fixture";
 for(const rate of ["+20%",""]) {process.env.QA_VOICE_TTS_RATE=rate;await speak("hello",{mode:"announce"});await awaitCurrentPlayback();}
 expect(synthArgs()).toEqual([["--voice=en-US-AriaNeural","--rate=+10%"],["--voice=en-US-AriaNeural","--rate=+10%"]]);
});
test("R2 saved or env clone rates never replace edge mode on synthesis fallback",async()=>{
 cloneFixture(null);writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"fixture",rate:"+20%"}}}));
 for(const rate of [undefined,"", "+50%"]) {if(rate===undefined) delete process.env.QA_VOICE_TTS_RATE;else process.env.QA_VOICE_TTS_RATE=rate;await speak("hello",{mode:"announce"});await awaitCurrentPlayback();}
 expect(synthArgs().map(a=>a[1])).toEqual(["--rate=+10%","--rate=+10%","--rate=+10%"]);
});
test("R4 a disappeared configured clone falls back with warning, but a mandate fails closed",async()=>{
 cloneFixture();writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,JSON.stringify({profiles:{short:{engine:"clone",voice:"missing"}}}));
 const logs=spyOn(console,"error").mockImplementation(()=>{});spies.push(logs);
 expect((await speak("hello")).engine).toBe("edge-tts");await awaitCurrentPlayback();
 expect(synthArgs()[0][0]).toBe("--voice=en-US-JennyNeural");
 expect(logs.mock.calls.some(([line])=>String(line).includes("missing") && String(line).includes("falling back"))).toBe(true);
 process.env.QA_VOICE_TTS_REQUIRE_CLONE="1";
 await expect(speak("hello")).rejects.toBeInstanceOf(VoiceProfileUnavailableError);
 expect(synthArgs()).toHaveLength(1);
});
