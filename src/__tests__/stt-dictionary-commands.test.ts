/** Dictionary commands remain separate: word/quill. becomes word /quill.
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { mainNormalizePathTokens } from "./fixtures/stt-path-main-7d13b620";
import { TEST_TMP } from "./setup/test-tmp";
import { cleanupTranscriptionText, normalizePathTokens } from "../stt-cleanup";

let directory = "";
let env: { QA_VOICE_STT_VOCABULARY_PATH: string; QA_VOICE_STT_COMMANDS_DIR: string };

beforeAll(() => {
  directory = mkdtempSync(join(TEST_TMP, "dict-cmds-"));
  env = { QA_VOICE_STT_VOCABULARY_PATH: join(directory, "vocabulary.json"), QA_VOICE_STT_COMMANDS_DIR: "" };
  writeFileSync(env.QA_VOICE_STT_VOCABULARY_PATH, JSON.stringify({
    entries: [
      { canonical: "/zephyr-sweep", variants: [] },
      { canonical: "/quill", variants: [] },
      { canonical: "/other", variants: [] },
    ],
  }));
});

afterAll(() => {
  rmSync(directory, { recursive: true, force: true });
});

const clean = (raw: string) => cleanupTranscriptionText(raw, env);
const expectControl = () =>
  expect(clean("And to tidy up, you just slash zephyr sweep.")).toBe("And to tidy up, you just /zephyr-sweep.");

describe("a dictionary command stays its own token", () => {
  it("control: keeps one space before a command that ends the sentence", () => {
    expectControl();
  });

  it("keeps the command before a question mark, a comma and the end of text", () => {
    expect(clean("should I run slash quill?")).toBe("Should I run /quill?");
    expect(clean("run slash quill, then rest")).toBe("Run /quill, then rest");
    expect(clean("you just slash quill")).toBe("You just /quill");
  });

  it("starts the text or a line with no space before it", () => {
    expect(clean("slash quill now.")).toBe("/quill now.");
    expect(clean("Done.\nslash quill now.")).toBe("done.\n/quill now.");
  });

  it("keeps two commands in a row as two tokens with one space", () => {
    expect(clean("then run slash zephyr sweep slash quill.")).toBe("Then run /zephyr-sweep /quill.");
  });

  // Round 2 (Codex P1): no placeholder is put in the text, so characters the
  // recognizer already wrote are never turned into a command or leaked.
  it("leaves private-use characters next to a command untouched", () => {
    expect(clean("keep \uE400\uE500\uE401 and \uF900 here, you just slash quill."))
      .toBe("Keep \uE400\uE500\uE401 and \uF900 here, you just /quill.");
    expect(clean("you just slash quill \uE400\uE500\uE401.")).toBe("You just /quill \uE400\uE500\uE401.");
  });

  it("keeps several thousand protected commands correct", () => {
    const many = (sentence: string) => Array.from({ length: 5200 }, () => sentence).join(" ");
    expect(clean(many("run slash quill."))).toBe(many("run /quill."));
  }, 30_000);

  // Lead ruling (Codex P2): a slash run made only of dictionary commands is
  // commands, even though the same sounds could be read as a path.
  it("reads a run made only of dictionary commands as commands", () => {
    expect(clean("run slash quill slash zephyr sweep")).toBe("run /quill /zephyr-sweep");
  });

  // Codex P2 (provenance): text matching, so a "/quill" the recognizer wrote
  // itself is protected exactly like one the dictionary produced.
  it("protects a literal /quill the recognizer wrote, like a dictionary one", () => {
    expect(clean("you just /quill.")).toBe("You just /quill.");
    expect(clean("open src/quill/index now.")).toBe("Open src/quill/index now.");
  });

  // Legacy path controls, with dictionary-boundary expectations updated to this brief.
  it("keeps legacy controls and the new command boundaries", () => {
    for (const [raw, candidate] of [
      ["Run slash quill then rest.", "Run /quill then rest."],
      ["and slash or", "And / or"],
      ["24 slash 7", "24/7"],
      ["view slash model", "View / model"],
      ["view slash model.", "view/model."],
      ["yes slash no.", "yes/no."],
      ["the review slash approval step", "The review / approval step"],
      ["open src slash rules engine dot ts", "Open src / rules engine .ts"],
      ["open tilde slash code slash notes.", "Open ~/code/notes."],
      ["see https://example.com/quill for more.", "See HTTPS://example.com/quill for more."],
      // The joining rule retains whitespace before a written dictionary command.
      ["run slash quill slash index", "run /quill/index"],
      ["run slash quill slash zephyr sweep slash index", "run /quill /zephyr-sweep/index"],
      // Slashes without a written standalone command keep their original behavior.
      ["open src slash slash quill.", "Open src / /quill."],
      ["open src/ slash quill.", "Open src/ /quill."],
      ["edit notes.ts slash quill.", "Edit notes.ts /quill."],
      ["go to tilde slash quill.", "Go to ~ /quill."],
    ] as const) {
      expect(clean(raw)).toBe(candidate);
    }
  });
});

for (const [suffix, name] of [[".", "period"], [", then rest", "comma"], ["?", "question"], ["", "end"]]) {
  it(`independent command before ${name}`, () => {
    expect(clean(`open ~/foo then run slash quill${suffix}`)).toBe(`Open ~/foo then run /quill${suffix}`);
  });
}
it("keeps the tilde hyphen seam", () => {
  expect(normalizePathTokens("open ~/foo then run- /quill", new Set(["/quill"])))
    .toBe("open ~/foo then run- /quill");
});
it("keeps a command after a comma following a tilde clause", () => {
  expect(clean("open ~/foo, then run slash quill.")).toBe("Open ~/foo, then run /quill.");
});
it.each(["src / quill / index", "~/ foo / quill"])("keeps real path %s", (input) => {
  expect(normalizePathTokens(input, new Set(["/quill"]))).toBe(mainNormalizePathTokens(input));
});

it("600 seeded inputs retain main bytes with empty and absent command sets", () => {
  let seed = 0x241;
  const atoms = ["Birch", "quill", "/", "-", "~", ".", ",", ";", "!", "?", " ", "  ", "\n"];
  for (let i = 0; i < 600; i++) {
    let input = "";
    for (let j = 0; j < 80; j++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      input += atoms[seed % atoms.length];
    }
    const baseline = mainNormalizePathTokens(input);
    expect(normalizePathTokens(input), input).toBe(baseline);
    expect(normalizePathTokens(input, new Set(["/zephyr-sweep", "/other"])), input).toBe(baseline);
  }
});
it("200 KiB of slash/hyphen near misses stays under the existing 100 ms bound", () => {
  const input = "a" + "- /".repeat(68266) + "x!";
  const start = performance.now();
  const output = normalizePathTokens(input, new Set(["/quill"]));
  const elapsed = performance.now() - start;
  expect(output).toBe(mainNormalizePathTokens(input));
  expect(elapsed).toBeLessThan(100);
});
