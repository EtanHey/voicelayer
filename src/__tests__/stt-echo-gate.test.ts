import { expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { stripAudioUnsupportedEcho } from "../stt-echo-gate";
import { WhisperServerBackend } from "../stt";
import type { TranscriptSegment } from "../stt-transcript-alignment";

function wav(seconds=10, spokenTwice=false, peak=8000, noise=12) {
  const rate=16000, frames=seconds*rate, b=Buffer.alloc(44+frames*2);
  b.write("RIFF");b.writeUInt32LE(b.length-8,4);b.write("WAVEfmt ",8);
  b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(1,22);
  b.writeUInt32LE(rate,24);b.writeUInt32LE(rate*2,28);b.writeUInt16LE(2,32);b.writeUInt16LE(16,34);
  b.write("data",36);b.writeUInt32LE(frames*2,40);
  for(let i=0;i<frames;i++) { const t=i/rate;
    const on=(t>=1&&t<4)||(spokenTwice&&t>=6&&t<8);
    b.writeInt16LE(Math.round((on?peak:noise)*Math.sin(2*Math.PI*220*t)),44+i*2);
  } return b;
}
const text="Keep every word. A separate thought. Keep every word.";
const segments:TranscriptSegment[]=[
  {text:"Keep every word.",startS:1,endS:2},
  {text:"A separate thought.",startS:2,endS:4},
  {text:"Keep every word.",startS:6,endS:8},
];
const opts={segments,segmentsText:text};

test("quiet repeated suffix is removed; exact surviving segment mapping retained",()=>{
 const r=stripAudioUnsupportedEcho(text,wav(),opts);
 expect(r.text).toBe("Keep every word. A separate thought.");
 expect(r.removedWords).toBe(3);expect(r.segments).toEqual(segments.slice(0,2));
 expect(r.segmentsText).toBe(r.text);
});
test("loud spoken-twice suffix stays",()=>expect(stripAudioUnsupportedEcho(text,wav(10,true),opts).text).toBe(text));
test("quiet recording speech-level guard keeps low-gain spoken repetition",()=>{
 const r=stripAudioUnsupportedEcho(text,wav(10,true,130,60),opts);
 expect(r.text).toBe(text);expect(r.reason).toBe("near-speech-level");
});
test("clearance margin keeps speech just before the attributed span",()=>{
 const shifted=segments.map((s,i)=>i===2?{...s,startS:8.02,endS:9}:s);
 expect(stripAudioUnsupportedEcho(text,wav(10,true),{segments:shifted,segmentsText:text}).text).toBe(text);
});
for(const [name,options] of [
 ["no timestamps",{}], ["stale prefix",{...opts,segmentsText:"A new prefix. "+text}],
 ["wrong audio",{...opts,segmentsMatchAudio:false}],
 ["out of file",{...opts,segments:segments.map((s,i)=>i===2?{...s,endS:10.01}:s)}],
 ["negative",{...opts,segments:segments.map((s,i)=>i===2?{...s,startS:-1}:s)}],
 ["nonfinite",{...opts,segments:segments.map((s,i)=>i===2?{...s,endS:NaN}:s)}],
 ["reversed",{...opts,segments:segments.map((s,i)=>i===2?{...s,endS:5}:s)}],
 ["overlapping",{...opts,segments:segments.map((s,i)=>i===2?{...s,startS:3}:s)}],
 ["segment stream mismatch",{...opts,segments:segments.slice(1)}],
] as const)test("KEEP "+name,()=>expect(stripAudioUnsupportedEcho(text,wav(),options).text).toBe(text));
for(const raw of ["Keep fu… here. A thought. Keep fu here.","Use red, no, blue. A thought. Use red, no, blue.","Use C++ for this. A thought. Use C for this."]){
 test("conserves fragments, retractions and code identity "+raw.length,()=>{
  const ss=[{text:raw,startS:1,endS:8}];
  expect(stripAudioUnsupportedEcho(raw,wav(10,true),{segments:ss,segmentsText:raw}).text).toBe(raw);
 });
}
test("cut inside a segment invalidates timing instead of inventing it",()=>{
 const ss=[{text:"Keep every word.",startS:1,endS:2},{text:"A separate thought. Keep every word.",startS:6,endS:8}];
 const r=stripAudioUnsupportedEcho(text,wav(),{segments:ss,segmentsText:text});
 expect(r.removedWords).toBe(3);expect(r.segments).toBeUndefined();
});
test("production whole-recording backend applies gate and retains prefix mapping",async()=>{
 const path=join(process.env.VOICELAYER_TEST_RUN_ROOT!,"echo.wav");writeFileSync(path,wav());
 const backend=new WhisperServerBackend({isServerAvailable:()=>true,
  transcribeViaServer:async(_a,options)=>{options?.onSegments?.(segments);return text;}});
 const r=await backend.transcribe(path);
 expect(r.text).toBe("Keep every word. A separate thought.");expect(r.segments).toEqual(segments.slice(0,2));
});

test("invalid WAV is inert even with timestamps",()=>{
 expect(stripAudioUnsupportedEcho(text,new Uint8Array(),opts).text).toBe(text);
});
