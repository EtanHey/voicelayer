import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { speak, awaitCurrentPlayback, stopPlayback } from "../tts";
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
 saved=Object.fromEntries(["VOICELAYER_TTS_SETTINGS_PATH","QA_VOICE_TTS_VOICE","QA_VOICE_TTS_RATE"].map(k=>[k,process.env[k]]));
 process.env.VOICELAYER_TTS_SETTINGS_PATH=join(dir,"settings.json"); delete process.env.QA_VOICE_TTS_VOICE; delete process.env.QA_VOICE_TTS_RATE;
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
test("unset settings preserve byte-identical legacy voice/rate argv across modes and lengths",async()=>{
 for(const [text,options]of [["hello",undefined],["hello",{mode:"announce"}],["hello",{mode:"brief"}],["x".repeat(650),{mode:"consult"}],["hello",{rate:"+25%"}]] as const){await speak(text,options);await awaitCurrentPlayback();}
 expect(synthArgs()).toEqual([["--voice=en-US-JennyNeural","--rate=+0%"],["--voice=en-US-JennyNeural","--rate=+10%"],["--voice=en-US-JennyNeural","--rate=-10%"],["--voice=en-US-JennyNeural","--rate=-5%"],["--voice=en-US-JennyNeural","--rate=-5%"],["--voice=en-US-JennyNeural","--rate=+25%"]]);
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
