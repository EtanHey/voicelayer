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
  it("does not read an unfinished fenced code block", () => expect(markdownToSpeech("Hi\n```js\nsecret()")).toBe("Hi code block"));
});
