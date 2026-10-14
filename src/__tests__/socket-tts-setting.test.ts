import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import * as qwen from "../tts/qwen3";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
const dir=join(TEST_TMP,"socket-tts"); let savedPath:string|undefined;let savedRate:string|undefined;
beforeEach(()=>{mkdirSync(dir,{recursive:true});savedPath=process.env.VOICELAYER_TTS_SETTINGS_PATH;savedRate=process.env.QA_VOICE_TTS_RATE;process.env.VOICELAYER_TTS_SETTINGS_PATH=join(dir,"settings.json");delete process.env.QA_VOICE_TTS_RATE;});
afterEach(()=>{for(const [k,v] of [["VOICELAYER_TTS_SETTINGS_PATH",savedPath],["QA_VOICE_TTS_RATE",savedRate]]){if(v===undefined)delete process.env[k!];else process.env[k!]=v;}rmSync(dir,{recursive:true,force:true});});
test("parses only valid setting keys and values, retaining command id",()=>{
 expect(parseCommand('{"cmd":"set_tts_setting","key":"long.rate","value":"+10%","id":"a"}')).toEqual({cmd:"set_tts_setting",key:"long.rate",value:"+10%",id:"a"});
 for(const [key,value]of [["voice","abc"],["short.rate","oops"],["long.engine","kokoro"],["short_limit_chars",-1]])expect(parseCommand(JSON.stringify({cmd:"set_tts_setting",key,value}))).toBeNull();
});
test("writes setting and acknowledges fresh controls",async()=>{
 const ack=await handleSocketCommand({cmd:"set_tts_setting",key:"long.rate",value:"+10%",id:"a"} as never);
 expect(ack).toMatchObject({type:"ack",command:"set_tts_setting",id:"a",outcome:"accept",tts_controls:{profiles:{long:{rate:{source:"settings",effective:"+10%"}}}}});
 expect(JSON.parse(readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).profiles.long.rate).toBe("+10%");
});
test("defined empty env rejects writes and names the lock",async()=>{
 process.env.QA_VOICE_TTS_RATE="";
 const ack=await handleSocketCommand({cmd:"set_tts_setting",key:"short.rate",value:"+10%"} as never);
 expect(ack).toMatchObject({outcome:"reject",reason:"Set by QA_VOICE_TTS_RATE"});
 expect(()=>readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).toThrow();
});

test("R4 rejects inconsistent single-field writes without creating a file",async()=>{
 const ack=await handleSocketCommand({cmd:"set_tts_setting",key:"short.engine",value:"clone"} as never);
 expect(ack).toMatchObject({outcome:"reject"});expect(()=>readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).toThrow();
});
test("R4 atomic profile payload switches both fields and acknowledges the stable shape",async()=>{
 const payload={cmd:"set_tts_setting",profile:"short",engine:"clone",voice:"  fixture  ",rate:"+20%",id:"pair"};
 const profile=spyOn(qwen,"hasClonedProfile").mockImplementation(v=>v==="fixture");
 try {
  expect(parseCommand(JSON.stringify(payload))).toEqual(payload);
  const ack=await handleSocketCommand(payload as never);
  expect(ack).toMatchObject({outcome:"accept",id:"pair",tts_controls:{profiles:{short:{engine:{effective:"clone"},voice:{effective:"fixture"}}}}});
  expect(JSON.parse(readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).profiles.short).toEqual({engine:"clone",voice:"fixture",rate:"+20%"});
  const back={cmd:"set_tts_setting",profile:"short",engine:"edge",voice:"en-US-JennyNeural"};
  expect(await handleSocketCommand(back as never)).toMatchObject({outcome:"accept"});
 } finally {profile.mockRestore();}
});
test("R4 invalid atomic payloads and env locks preserve the prior file",async()=>{
 const profile=spyOn(qwen,"hasClonedProfile").mockImplementation(v=>v==="fixture");
 const savedVoice=process.env.QA_VOICE_TTS_VOICE;
 try {
  delete process.env.QA_VOICE_TTS_VOICE;
  await handleSocketCommand({cmd:"set_tts_setting",profile:"short",engine:"clone",voice:"fixture",rate:"+20%"} as never);
  const previous=readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8");
  for(const payload of [
   {cmd:"set_tts_setting",key:"short.voice",value:"en-US-JennyNeural"},
   {cmd:"set_tts_setting",key:"short.engine",value:"edge"},
   {cmd:"set_tts_setting",profile:"short",engine:"clone",voice:"missing"},
  ]) expect(await handleSocketCommand(payload as never)).toMatchObject({outcome:"reject"});
  expect(readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).toBe(previous);
  process.env.QA_VOICE_TTS_VOICE="";
  expect(await handleSocketCommand({cmd:"set_tts_setting",profile:"short",engine:"edge",voice:"en-US-JennyNeural"} as never)).toMatchObject({outcome:"reject",reason:"Set by QA_VOICE_TTS_VOICE"});
  expect(readFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH!,"utf8")).toBe(previous);
  for(const payload of [
   {profile:"other",engine:"edge",voice:"en-US-JennyNeural"},
   {profile:"short",engine:"clone",voice:"fixture",rate:"fast"},
   {profile:"short",engine:"clone",voice:"fixture",key:"short.rate",value:"+10%"},
   {profile:"short",engine:"clone"},
  ]) expect(parseCommand(JSON.stringify({cmd:"set_tts_setting",...payload}))).toBeNull();
 } finally {profile.mockRestore();if(savedVoice===undefined)delete process.env.QA_VOICE_TTS_VOICE;else process.env.QA_VOICE_TTS_VOICE=savedVoice;}
});
