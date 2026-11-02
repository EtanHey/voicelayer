import { afterAll, expect, test } from 'bun:test';
import { testSocket } from './setup/test-tmp';

import { finalizeTranscriptionResultForSurface, finalizeTranscriptionText } from '../input';
import { polishTranscriptionText } from '../stt-polish';
let reply = '';
const server = Bun.serve({hostname:'127.0.0.1',port:0,fetch:req=>
  Response.json(req.method==='GET'?{status:'ok'}:{choices:[{message:{content:reply}}]})});
afterAll(()=>server.stop(true));
const env = {...process.env, QA_VOICE_STT_POLISH:'on',
  QA_VOICE_STT_POLISH_ENDPOINT:`http://127.0.0.1:${server.port}/v1/chat/completions`,
  QA_VOICE_STT_POLISH_TIMEOUT_MS:'5000', VOICELAYER_STT_POLISH_ADDED_CONTENT_GUARD:'off',
  VOICELAYER_STT_COHERENT_PARAGRAPHS:'0', VOICELAYER_STT_PAUSE_PARAGRAPHS:'0'};
const prefix='Please inspect the recording carefully before release and preserve every spoken word in the final saved transcript.';
const rejects = [
  ['interior word',`${prefix} The amber lantern remains beside the garden gate.`,`${prefix} The lantern remains beside the garden gate.`],
  ['true repetition',`${prefix} We need the complete result. We need the complete result.`,`${prefix} We need the complete result.`],
  ['final six words',`${prefix} The final amber lantern stays outside.`,prefix],
  ['retraction without dash',`${prefix} Choose the red option sorry choose the blue option.`,`${prefix} Choose the blue option.`],
  ['short word',`${prefix} Keep it in a safe place.`,`${prefix} Keep it in safe place.`],
  ['inserted clause',`${prefix} The release can wait.`,`${prefix} The release can wait because the team approved it.`],
  ['same length replacement',`${prefix} The blue lantern remains.`,`${prefix} The gold lantern remains.`],
  ['reordered words',`${prefix} Red follows blue and amber follows green.`,`${prefix} Blue follows red and amber follows green.`],
  ['fragment loss',`${prefix} Keep the fu… fragment before release.`,`${prefix} Keep the fragment before release.`],
  ['fragment expansion',`${prefix} Keep the fu… fragment before release.`,`${prefix} Keep the full fragment before release.`],
  ['word boundaries','Please tell us why the rapist escaped before the hearing.','Please tell us why therapist escaped before the hearing.'],
  ['arbitrary identifier split','Please hand le socket command to the operator.','Please handleSocketCommand to the operator.'],
] as const;
const safe = [
  ['punctuation and casing','please keep every word here and save the final answer','Please keep every word here, and save the final answer.'],
  ['paragraphs',`${prefix} The first sentence belongs here. The next sentence belongs below.`,`${prefix}\n\nThe first sentence belongs here.\n\nThe next sentence belongs below.`],
  ['number spelling','Review 42 dashboard files before 6pm.','Review forty two dashboard files before 6pm.'],
  ['hyphenated number spelling','Review 42 dashboard files before 6pm.','Review forty-two dashboard files before 6pm.'],
  ['known identifier','תרים את ה handle socket command','תרים את ה-handleSocketCommand'],
  ['literal path','Read .env and src/input.ts before release.','Read .env and src/input.ts before release.'],
  ['fragment and multiplicity','Keep the fu… fragment and both repeated repeated words.','Keep the fu… fragment, and both repeated repeated words.'],
  ['pure prose dash','Keep all words here - this clause must survive.','Keep all words here — this clause must survive.'],
] as const;
for(const surface of ['dictation','voice_ask'] as const) {
  for(const [label,raw,candidate] of rejects) test(`${surface} full caller conserves ${label}`,async()=>{
    reply=candidate;
    const result=await finalizeTranscriptionResultForSurface(raw,surface,env);
    expect(result.polishStatus).toBe('rejected');
    expect(result.text).toBe(finalizeTranscriptionText(raw,env));
  });
  for(const [label,raw,candidate] of safe) test(`${surface} full caller accepts ${label}`,async()=>{
    reply=candidate;
    const result=await finalizeTranscriptionResultForSurface(raw,surface,env);
    expect(result.polishStatus).toBe('applied');
    expect(result.text).toBe(candidate);
  });
  for(const [label,cleaned,candidate] of [
    ['filler deletion','Alpha um bravo charlie delta echo foxtrot golf.','Alpha bravo charlie delta echo foxtrot golf.'],
    ['article replacement','I mean choose a ultra detailed answer.','I mean choose an ultra detailed answer.'],
    ['zero changed to no','There are 0 issues and the result is ready.','There are no issues and the result is ready.'],
    ['spoken ordinal deletion','First, keep every raw word. Second, save every recording.','1. Keep every raw word.\n2. Save every recording.'],
  ]) test(`${surface} validator rejects ${label}`,async()=>{
    reply=candidate;
    const result=await polishTranscriptionText({rawText:cleaned,cleanedText:cleaned,surface,env});
    expect(result.status).toBe('rejected');
    expect(result.text).toBe(cleaned);
  });
  test(`${surface} socket uses the same default guard`,async()=>{
    const raw=`${prefix} The blue lantern remains.`;
    const socket=testSocket(surface==='dictation'?'dict.sock':'ask.sock');
    const peer=Bun.listen({unix:socket,socket:{data(client){client.write(JSON.stringify({text:`${prefix} The gold lantern remains.`})+'\n');},drain(){}}});
    try {
      const socketEnv={...env,QA_VOICE_STT_POLISH_ENDPOINT:undefined,QA_VOICE_STT_POLISH_SOCKET:socket};
      const result=await finalizeTranscriptionResultForSurface(raw,surface,socketEnv);
      expect(result.polishStatus).toBe('rejected');
      expect(result.text).toBe(raw);
    } finally { peer.stop(true); }
  });
  test(`${surface} shadow keeps supplied text and records lexical refusal`,async()=>{
    const raw=`${prefix} The blue lantern remains.`;
    reply=`${prefix} The gold lantern remains.`;
    const result=await finalizeTranscriptionResultForSurface(raw,surface,{...env,QA_VOICE_STT_POLISH:'shadow'});
    expect(result.polishStatus).toBe('shadowed');
    expect(result.polishReason).toContain('changed lexical content or order');
    expect(result.text).toBe(raw);
  });
}
