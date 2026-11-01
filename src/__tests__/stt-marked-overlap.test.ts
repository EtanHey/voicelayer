import {test,expect} from "bun:test";
import {mergeChunkTranscripts,mergeChunkTranscriptsWithSegments} from "../stt";
const cases=[
 {name:"compact nonmatching marked base",first:"please use the function name",next:"please use the functionname… and continue",expected:"please use the function name and continue"},
 {name:"equal marked base survives",first:"please use the function name",next:"please use the function name… and continue",expected:"please use the function name… and continue"},
 {name:"current marked base survives",first:"please use the function name…",next:"please use the function name and continue",expected:"please use the function name… and continue"},
];
for(const c of cases){
 test(c.name+" text",()=>{expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");expect(mergeChunkTranscripts([c.first,c.next])).toBe(c.expected);});
 test(c.name+" timed",()=>{expect(mergeChunkTranscriptsWithSegments([{text:c.first,startSeconds:0,segments:[{text:c.first,startS:20,endS:30}]},{text:c.next,startSeconds:25,segments:[{text:c.next,startS:0,endS:10}]}]).text).toBe(c.expected);});
}
