import {test,expect} from "bun:test";
import {mergeChunkTranscripts,mergeChunkTranscriptsWithSegments} from "../stt";
const cases=[
 {name:"compact nonmatching marked base",first:"please use the function name",next:"please use the functionname… and continue",expected:"please use the function name and continue"},
 {name:"equal marked base survives",first:"please use the function name",next:"please use the function name… and continue",expected:"please use the function name… and continue"},
 {name:"current marked base survives",first:"please use the function name…",next:"please use the function name and continue",expected:"please use the function name… and continue"},
 {name:"apostrophe equivalent keeps cutoff",first:"we all know that it’s",next:"we all know that it's… difficult",expected:"we all know that it's… difficult"},
 {name:"hyphen equivalent keeps cutoff",first:"please remember the non-linear",next:"please remember the nonlinear… operation",expected:"please remember the nonlinear… operation"},
 {name:"Unicode equivalent keeps cutoff",first:"please remember the ﬁx",next:"please remember the fix… today",expected:"please remember the fix… today"},
 {name:"earlier fragment keeps the full next word",first:"Start with the long shared anchor fu…",next:"the long shared anchor function and continue",expected:"Start with the long shared anchor fu… function and continue"},
 {name:"earlier fragment keeps a different next word",first:"Start with the long shared anchor fu…",next:"the long shared anchor funny and continue",expected:"Start with the long shared anchor fu… funny and continue"},
 {name:"identical fragments share one occurrence",first:"please use the fu…",next:"please use the fu… and continue",expected:"please use the fu… and continue"},
];
for(const c of cases){
 test(c.name+" text",()=>{expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");expect(mergeChunkTranscripts([c.first,c.next])).toBe(c.expected);});
 test(c.name+" timed",()=>{expect(mergeChunkTranscriptsWithSegments([{text:c.first,startSeconds:0,segments:[{text:c.first,startS:20,endS:30}]},{text:c.next,startSeconds:25,segments:[{text:c.next,startS:0,endS:10}]}]).text).toBe(c.expected);});
}
