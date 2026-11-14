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
  expect(clean("Zorple glim narb, flarn slash zephyr sweep.")).toBe("Zorple glim narb, flarn /zephyr-sweep.");

describe("a dictionary command stays its own token", () => {
  it("control: keeps one space before a command that ends the sentence", () => {
    expectControl();
  });

  it("keeps the command before a question mark, a comma and the end of text", () => {
    expect(clean("should I run slash quill?")).toBe("Should I run /quill?");
    expect(clean("run slash quill, then rest")).toBe("Run /quill, then rest");
    expect(clean("flarn zib slash quill")).toBe("Flarn zib /quill");
  });

  it("starts the text or a line with no space before it", () => {
    expect(clean("slash quill now.")).toBe("/quill now.");
    expect(clean("Done.\nslash quill now.")).toBe("Done.\n/quill now.");
  });

  it("keeps two commands in a row as two tokens with one space", () => {
    expect(clean("then run slash zephyr sweep slash quill.")).toBe("Then run /zephyr-sweep /quill.");
  });

  // Round 2 (Codex P1): no placeholder is put in the text, so characters the
  // recognizer already wrote are never turned into a command or leaked.
  it("leaves private-use characters next to a command untouched", () => {
    expect(clean("zib \uE400\uE500\uE401 norp \uF900 blim, flarn zib slash quill."))
      .toBe("Zib \uE400\uE500\uE401 norp \uF900 blim, flarn zib /quill.");
    expect(clean("flarn zib slash quill \uE400\uE500\uE401.")).toBe("Flarn zib /quill \uE400\uE500\uE401.");
  });

  it("keeps several thousand protected commands correct", () => {
    const many = (sentence: string) => Array.from({ length: 5200 }, () => sentence).join(" ");
    expect(clean(many("run slash quill."))).toBe(many("Run /quill."));
  }, 30_000);

  // Lead ruling (Codex P2): a slash run made only of dictionary commands is
  // commands, even though the same sounds could be read as a path.
  it("reads a run made only of dictionary commands as commands", () => {
    expect(clean("run slash quill slash zephyr sweep")).toBe("Run /quill /zephyr-sweep");
  });

  // Codex P2 (provenance): text matching, so a "/quill" the recognizer wrote
  // itself is protected exactly like one the dictionary produced.
  it("protects a literal /quill the recognizer wrote, like a dictionary one", () => {
    expect(clean("flarn zib /quill.")).toBe("Flarn zib /quill.");
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
      // N1: a command followed by a joined separator is a path segment.
      ["run slash quill slash index", "run/quill/index"],
      ["run slash quill slash zephyr sweep slash index", "run/quill/zephyr-sweep/index"],
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

const commands = new Set(["/quill", "/other"]);
const caseControls = [
  ["ask Claude /quill.", "ask Claude /quill."],
  ["Use GitHub /quill /other.", "Use GitHub /quill /other."],
  ["Done.\n/quill now.", "Done.\n/quill now."],
  ...[".", ",", "?", ";", ":", ""].map((suffix) =>
    [`Birch /quill${suffix}`, `Birch /quill${suffix}`]),
  ["NASA /quill.", "NASA /quill."],
  ["Birch /quill /other.", "Birch /quill /other."],
  ["See Src / Foo. Birch /quill.", "See src/foo. Birch /quill."],
] as const;

for (const [input, expected] of caseControls) {
  it(`path callback preserves non-path case: ${JSON.stringify(input)}`, () => {
    expect(normalizePathTokens(input, commands)).toBe(expected);
  });
  it(`cleanup preserves non-path case: ${JSON.stringify(input)}`, () => {
    expect(clean(input)).toBe(input.startsWith("ask ") ? `Ask${expected.slice(3)}` : expected);
  });
}

it("lowercases the matched tilde clause as on main", () => {
  expect(normalizePathTokens("open ~/Foo then Run- /quill", commands))
    .toBe("open ~/foo then run- /quill");
});

it("300 seeded command-boundary inputs differ from main only by separation and non-path case", () => {
  let seed = 0x241ca5e;
  const pick = <T,>(items: readonly T[]): T => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return items[(seed >>> 8) % items.length];
  };
  for (let i = 0; i < 300; i++) {
    const word = pick(["Birch", "NASA", "MapLe", "CEDAR"]);
    const space = pick([" ", "  ", "\n", "\t"]);
    const prefix = pick(["", "see ", "see Src / Foo, ", "see Src / Foo "]);
    const tail = pick([".", ",", "?", ";", ":", "", " now."]);
    const second = pick(["", `${space}/other`]);
    const input = `${prefix}${word}${space}/quill${second}${tail}`;
    // Oracle: start with the frozen main implementation. Restore only the
    // original whitespace run at each known command boundary and the case of
    // the generated non-path word; every other byte must remain main's output.
    const baseline = mainNormalizePathTokens(input);
    const expected = baseline
      .replace(/\s*\/(quill|other)\b/gu, (_match, command) => `${space}/${command}`)
      .replace(new RegExp(word, "giu"), word);
    expect(normalizePathTokens(input, commands), input).toBe(expected);
  }
});

it("lowercases a joined path before a kept command", () => {
  expect(normalizePathTokens("see src / Foo /quill.", commands))
    .toBe("see src/foo /quill.");
});

it("returns a non-path span unchanged, including hyphen spacing and command whitespace", () => {
  expect(normalizePathTokens("Birch - Maple  /quill.", commands))
    .toBe("Birch - Maple  /quill.");
});

// B1: a pre-join command can become a path segment; offsets must still refer
// to the same original characters when the later command is kept standalone.
for (const [input, expected] of [
  ["Foo /quill / Index /other.", "foo/quill/index /other."],
  ["A /other / B /quill.", "a/other/b /quill."],
  ["A /quill -B /other.", "a/quill-b /other."],
]) {
  it(`B1 offset regression: ${input}`, () => {
    expect(normalizePathTokens(input, commands)).toBe(expected);
  });
}
it("B1 pipeline does not repeat a command that became a path segment", () => {
  const pipelineEnv = { ...env, QA_VOICE_STT_VOCABULARY_PATH: join(directory, "pipeline.json") };
  writeFileSync(pipelineEnv.QA_VOICE_STT_VOCABULARY_PATH, JSON.stringify({ entries: [
    { canonical: "/think", variants: [] }, { canonical: "/brief", variants: [] },
  ] }));
  expect(cleanupTranscriptionText("open notes slash think slash index slash brief.", pipelineEnv))
    .toBe("Open notes/think/index /brief.");
});

it("20000 seeded inputs conserve main letters and keep non-path commands separate", () => {
  let seed = 0x241b1;
  const pick = <T,>(items: readonly T[]): T => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return items[(seed >>> 8) % items.length];
  };
  const atoms = ["Birch", "CEDAR", "MapLe", "42", "7X", " /quill", " /other",
    " /quill / Index", " /other -B", " / x", " -x", "~/", "/", "-",
    ".", ",", ";", "!", "?", " ", "  ", "\t", "\n"];
  let letterFailures = 0;
  let boundaryFailures = 0;
  const examples: string[] = [];
  for (let i = 0; i < 20000; i++) {
    const input = Array.from({ length: 8 + (i % 25) }, () => pick(atoms)).join(" ");
    const baseline = mainNormalizePathTokens(input);
    const output = normalizePathTokens(input, commands);
    // Align letters/digits only, allowing case differences solely at positions
    // inside main's joined path tokens (main also glued standalone commands).
    // Outside those paths the comparison is case-sensitive.
    const baselineLetters: string[] = [];
    const pathPositions: boolean[] = [];
    for (const token of baseline.matchAll(/\S+|\s+/gu)) {
      for (const char of token[0]) if (/[A-Za-z0-9]/u.test(char)) {
        baselineLetters.push(char);
        pathPositions.push(token[0].includes("/"));
      }
    }
    const letters = output.match(/[A-Za-z0-9]/gu) ?? [];
    const letterBad = letters.length !== baselineLetters.length || letters.some((char, index) =>
      pathPositions[index] ? char.toLowerCase() !== baselineLetters[index].toLowerCase() : char !== baselineLetters[index]);
    // Every generated command starts after whitespace. Joining may absorb that
    // whitespace only when the command has become a slash/hyphen path segment.
    const boundaryBad = [...output.matchAll(/\/(?:quill|other)(?=[\s.,;:!?/\-]|$)/gu)]
      .some((match) => match.index > 0 && !/[\s/]/u.test(output[match.index - 1]) &&
        !/[/-]/u.test(output[match.index + match[0].length] ?? ""));
    letterFailures += Number(letterBad);
    boundaryFailures += Number(boundaryBad);
    if ((letterBad || boundaryBad) && examples.length < 3) examples.push(input);
  }
  console.info(`T8A seeded differential: inputs=20000 letterFailures=${letterFailures} boundaryFailures=${boundaryFailures}`);
  expect(letterFailures, JSON.stringify(examples)).toBe(0);
  expect(boundaryFailures, JSON.stringify(examples)).toBe(0);
});
