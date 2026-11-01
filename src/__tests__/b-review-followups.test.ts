import { afterAll, expect, test } from "bun:test";
import { buildPolishSystemPrompt, polishTranscriptionText } from "../stt-polish";
import { finalizeTranscriptionResultForSurface } from "../input";
import { applyCoherentParagraphFallback } from "../stt-coherent-paragraphs";
import { applyPauseParagraphs } from "../stt-paragraphs";

const prose = [
 "We moved the release script into the shared folder before the team arrived.",
 "The script now builds the bundle and checks every file before sending the result.",
 "Signing takes a few minutes and we keep the complete build output for later inspection.",
 "The bundle then goes to the storage folder where the rest of the team can inspect it.",
 "Anyway we need to discuss dinner because the restaurant closes early on weeknights.",
 "The menu has several vegetarian dishes and everyone should choose something before we leave.",
 "We should book a table and tell the staff about the final number of guests.",
 "Another thing is the parking situation because the nearby streets get busy around sunset.",
].join(" ");
let response = "";
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: req =>
 Response.json(req.method === "GET" ? {status:"ok"} : {choices:[{message:{content:response}}]}) });
afterAll(() => server.stop(true));

test("polish examples preserve every supplied digit literal", () => {
 const prompt = buildPolishSystemPrompt();
 const examples = prompt.split(/(?=^Input: )/mu).slice(1);
 expect(examples.length).toBeGreaterThan(0);
 for (const example of examples) {
  const end = example.indexOf("\nOutput:");
  expect(end).toBeGreaterThan(0);
  const input = example.slice(7,end), output = example.slice(end+8);
  for (const literal of input.match(/\d+(?:\.\d+)*(?:%)?/gu) ?? []) expect(output).toContain(literal);
 }
 expect(prompt).not.toContain("Equivalent numeric spellings");
});
for (const value of ["PR 646", "version 2.2.59", "port 8880"]) test(`polish keeps ${value} in digit form`, async () => {
 const raw = "Please inspect the complete release details carefully and preserve " + value;
 response = raw + ".";
 const result = await polishTranscriptionText({rawText:raw,cleanedText:raw,surface:"dictation",env:{
  ...process.env, QA_VOICE_STT_POLISH:"on", QA_VOICE_STT_POLISH_ENDPOINT:`http://127.0.0.1:${server.port}/v1/chat/completions`,
  QA_VOICE_STT_POLISH_TIMEOUT_MS:"5000",
 }});
 expect(result.text).toBe(response);
 expect(result.status).not.toBe("failed");
});
for (const span of ["`bun test`", "`First code sentence ends here. Second code sentence stays here.`", "``value `nested`. Next code token``"]) {
 test(`long prose with inline code still gets paragraphs: ${span.length}`, async () => {
  const raw = prose.replace("Signing takes", "We execute " + span + " before release. Signing takes");
  for (const out of [applyCoherentParagraphFallback(raw),(await finalizeTranscriptionResultForSurface(raw,"dictation",{
   ...process.env,QA_VOICE_CORRECTOR:"identity",QA_VOICE_STT_POLISH:"off",
  })).text]) {
   expect(out.split("\n\n").length).toBeGreaterThan(1);
   expect(out).toContain(span);
   expect(out.replace(/\s/gu,"")).toBe(raw.replace(/\s/gu,""));
  }
 });
}
for (const raw of ["```text\n"+prose+"\n```", "~~~text\n"+prose+"\n~~~", "Before `first code line\nsecond code line` after. "+prose]) {
 test(`fenced or multiline code remains unchanged: ${raw.length}`, () => expect(applyCoherentParagraphFallback(raw)).toBe(raw));
}

test("an acoustic pause inside inline code cannot split the code span", async () => {
 const first = prose + " We inspect `First embedded example ends here.";
 const last = "Second embedded example stays within code` before continuing. " + prose;
 const raw = first + " " + last;
 const context = {segments:[{text:first,startS:0,endS:10},{text:last,startS:12,endS:30}],pauses:[{startS:10,endS:12}]};
 const unsafe = applyPauseParagraphs(raw,context.segments,context.pauses);
 expect(unsafe).toContain("example ends here.\n\nSecond embedded");
 const result = await finalizeTranscriptionResultForSurface(raw,"dictation",{
  ...process.env,QA_VOICE_CORRECTOR:"identity",QA_VOICE_STT_POLISH:"off",
  VOICELAYER_STT_COHERENT_PARAGRAPHS:"0",VOICELAYER_STT_PAUSE_PARAGRAPHS:"1",
 },context);
 expect(result.text).toContain("`First embedded example ends here. Second embedded example stays within code`");
 expect(result.text.split("\n\n").length).toBeGreaterThan(1);
 expect(result.text.replace(/\s/gu,"")).toBe(raw.replace(/\s/gu,""));
});

for (const base of ["um", "uh", "er"]) for (const marker of ["…", "...", "..", "-", "—"]) {
 test(`default filler cleanup preserves marked fragment ${base}/${marker}`, async () => {
  const fragment = base + marker;
  const raw = "Please keep the " + fragment + " fragment beside the complete recording details.";
  const result = await finalizeTranscriptionResultForSurface(raw,"dictation",{
   ...process.env,QA_VOICE_CORRECTOR:undefined,QA_VOICE_STT_POLISH:"off",
  });
  expect(result.text).toContain(fragment);
 });
}
test("ordinary unmarked acoustic fillers are still removed by default", async () => {
 const result = await finalizeTranscriptionResultForSurface("We um should uh review er the complete recording details.","dictation",{
  ...process.env,QA_VOICE_CORRECTOR:undefined,QA_VOICE_STT_POLISH:"off",
 });
 expect(result.text).not.toMatch(/\b(?:um|uh|er)\b/u);
 expect(result.text).toContain("We should review the complete recording details");
});
