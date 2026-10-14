import { describe, expect, it } from "bun:test";
import { markdownToSpeech } from "../tts/markdown-to-speech";

describe("markdownToSpeech", () => {
  for (const [input, output] of [
    ["# Heading\n\n**Bold** and _italic_ with `code`.", "Heading Bold and italic with code."],
    ["[VoiceLayer](https://example.com) and https://example.org/path", "VoiceLayer and link"],
    ["Before\n```ts\nconst secret = 42;\n```\nAfter", "Before code block After"],
    ["Before\n~~~python\nprint('hello')\n~~~\nAfter", "Before code block After"],
    ["- One\n* Two\n3. Three", "One. Two. Three."],
    ["| Name | Value |\n| --- | ---: |\n| A | 5 |", "Name, Value. A, 5."],
    ["שלום **עולם**", "שלום עולם"],
    ["Title\n=====\nVisit <https://example.com>.", "Title Visit link."],
    ["[A link](https://example.com/a_(b))", "A link"],
    ["A sentence.\n- Another sentence!", "A sentence. Another sentence!"],
  ]) it(`converts ${JSON.stringify(input)}`, () => expect(markdownToSpeech(input)).toBe(output));
  it("R1-3 preserves prose when a selection starts inside code before its closing fence", () => {
    expect(markdownToSpeech("const value = 1;\nconsole.log(value);\n```\nHere is the explanation.\nContinue reading."))
      .toBe("code block Here is the explanation. Continue reading.");
  });
  it("R1-3 preserves prose after an unmatched leading bare fence", () => {
    expect(markdownToSpeech("```\nHere is the explanation.\n- First point\n- Second point"))
      .toBe("code block Here is the explanation. First point. Second point.");
  });
  it("R1-3 preserves prose after an unclosed opening fence instead of swallowing the rest", () => {
    expect(markdownToSpeech("Hi\n```js\nsecret()\nAfter this incomplete example, keep this sentence."))
      .toBe("Hi code block After this incomplete example, keep this sentence.");
  });
  it("R1-3 a selection ending mid-code omits only recognizable code", () => {
    expect(markdownToSpeech("Before the example.\n```ts\nconst value = 1;\nconsole.log(value)"))
      .toBe("Before the example. code block");
  });
  it("R1-3 a leading closing fence does not steal the later code block's closing fence", () => {
    expect(markdownToSpeech("```\nHere is the explanation.\n```js\nconst next = 2;\n```\nMore prose."))
      .toBe("code block Here is the explanation. code block More prose.");
  });
  for (const identifier of ["voice_ask", "snake_case_name", "__init__"]) {
    it(`R1-4 preserves identifier ${identifier}`, () => expect(markdownToSpeech(identifier)).toBe(identifier));
  }
  it("R1-4 strips real emphasis at word boundaries without touching adjacent identifiers", () => {
    expect(markdownToSpeech("Use voice_ask and snake_case_name with _emphasis_ or (__init__)."))
      .toBe("Use voice_ask and snake_case_name with emphasis or (__init__).");
  });
});
