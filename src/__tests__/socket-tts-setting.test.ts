import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
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
