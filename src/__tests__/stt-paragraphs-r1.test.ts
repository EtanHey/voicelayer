import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { applyPauseParagraphs } from "../stt-paragraphs";
import { finalizeTranscriptionText } from "../input";
import * as journal from "../control-layer-journal";

const a = "Review the captured words carefully and retain all the original details about the current task, the archive recording, the chosen settings, the observed behavior, the pending verification, and the changes planned for tomorrow afternoon.";
const b = "Run the focused checks using synthetic examples and preserve all of the evidence about the original failure, the intended correction, the current branch, the immutable head, the test boundaries, and the result that the independent reviewer can inspect.";
const c = "Publish the reviewed change with a clear receipt covering the completed work, the reason for the correction, the local verification, the remaining hosted checks, the exact source version, and the next owner who will finish the review process.";
function evidence(parts: string[]) {
  return parts.map((text,i)=>({text,startS:i*23,endS:i*23+20}));
}
const pauses=[{startS:20,endS:23},{startS:43,endS:46}];
let append: ReturnType<typeof spyOn>;
beforeEach(()=>{append=spyOn(journal,"appendControlLayerEvent").mockImplementation(()=>{});});
afterEach(()=>append.mockRestore());

describe("paragraph review R1",()=>{
  test("real rules-engine numbered list retains all three item line breaks",()=>{
    const input=finalizeTranscriptionText(`First, ${a} Second, ${b} Third, ${c}`);
    const lines=input.split("\n");
    expect(lines.length).toBe(3);
    expect(lines.map(line=>line.slice(0,3))).toEqual(["1. ","2. ","3. "]);
    expect(applyPauseParagraphs(input,evidence(lines),pauses)).toBe(input);
  });
  for (const separator of ["\n","\r\n"]) {
    test(`spoken new line retains ${separator === "\n" ? "LF" : "CRLF"} bytes`,()=>{
      const cleaned=finalizeTranscriptionText(`${a} new line ${b}`);
      expect(cleaned).toContain("\n");
      const input=cleaned.replace(/\n/g,separator);
      expect(applyPauseParagraphs(input,evidence(input.split(separator)),pauses)).toBe(input);
    });
  }
  test("a two-sentence numbered item cannot be split internally",()=>{
    const parts=[`1. ${a}`,b,`2. ${c}`];
    const input=`${parts[0]} ${parts[1]}\n${parts[2]}`;
    expect(applyPauseParagraphs(input,evidence(parts),pauses)).toBe(input);
  });
  test("an empty acoustic map cannot fall back to segment gaps",()=>{
    const input=`${a} ${b} ${c}`;
    expect(applyPauseParagraphs(input,evidence([a,b,c]),[])).toBe(input);
  });
  test("alignment cell cap emits a numeric control-layer skip event",()=>{
    const parts=[Array.from({length:500},(_,i)=>`alpha${i}`).join(" ")+".",Array.from({length:500},(_,i)=>`beta${i}`).join(" ")+"."];
    const input=parts.join(" ");
    expect(applyPauseParagraphs(input,evidence(parts),pauses)).toBe(input);
    expect(append).toHaveBeenCalledWith("transcription.paragraphs.skipped",{
      reason:"alignment-cell-cap",alignment_cells:1002001,max_alignment_cells:1000000,
    },{topic:"voice.transcription"});
    expect(append.mock.calls[0]?.[1]).not.toHaveProperty("text");
  });
});
