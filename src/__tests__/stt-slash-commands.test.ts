/**
 * Lane c11-T8: a spoken slash command is its own token.
 *
 * "you just slash compact." came out as "you just/compact.": the dictionary
 * stage knew the command, but the later path pass glued it to the word before
 * whenever a full stop or a second command followed it. Mid-sentence the same
 * command survived, which is why it looked inconsistent. Built-in harness
 * commands (/compact, /model, …) were not known at all unless the user had
 * added them to the dictionary.
 *
 * Command names here are public harness commands or invented. Each test runs
 * the base-failing control, so every test fails on the base candidate.
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { cleanupTranscriptionText } from "../stt-cleanup";

let commandsDir = "";
let env: { QA_VOICE_STT_VOCABULARY_PATH: string; QA_VOICE_STT_COMMANDS_DIR: string };

beforeAll(() => {
  commandsDir = mkdtempSync(join(TEST_TMP, "slash-cmds-"));
  for (const name of ["zephyr-sweep", "quill", "tidy", "tidy-notes"]) {
    mkdirSync(join(commandsDir, name), { recursive: true });
    writeFileSync(join(commandsDir, name, "SKILL.md"), `# /${name}\n`);
  }
  env = { QA_VOICE_STT_VOCABULARY_PATH: "", QA_VOICE_STT_COMMANDS_DIR: commandsDir };
});

afterAll(() => {
  rmSync(commandsDir, { recursive: true, force: true });
});

const clean = (raw: string) => cleanupTranscriptionText(raw, env);
const expectControl = () =>
  expect(clean("And to tidy up, you just slash compact.")).toBe("And to tidy up, you just /compact.");

describe("a spoken slash command is one token", () => {
  it("keeps one space before a built-in command that ends the sentence", () => {
    expectControl();
  });

  it("keeps the command before a question mark", () => {
    expectControl();
    expect(clean("should I run slash compact?")).toBe("Should I run /compact?");
  });

  it("keeps punctuation after the command outside the token", () => {
    expectControl();
    expect(clean("run slash compact, then rest")).toBe("Run /compact, then rest");
  });

  it("starts the text with the command and never capitalises it", () => {
    expectControl();
    expect(clean("slash compact now.")).toBe("/compact now.");
  });

  it("starts a new sentence with the command and never capitalises it", () => {
    expectControl();
    expect(clean("Done. Slash compact now.")).toBe("Done. /compact now.");
  });

  it("starts a new line with the command, with no space before it", () => {
    expectControl();
    expect(clean("first line\nslash compact.")).toBe("First line\n/compact.");
  });

  it("follows a comma with one space", () => {
    expectControl();
    expect(clean("first, slash quill.")).toBe("First, /quill.");
  });

  it("spells an installed multi-word name with its hyphen", () => {
    expectControl();
    expect(clean("run slash zephyr sweep.")).toBe("Run /zephyr-sweep.");
  });

  it("keeps two commands in a row as two tokens one space apart", () => {
    expectControl();
    expect(clean("say slash zephyr sweep slash tidy notes now")).toBe(
      "Say /zephyr-sweep /tidy-notes now",
    );
    expect(clean("say slash zephyr sweep slash quill.")).toBe("Say /zephyr-sweep /quill.");
  });

  it("lets the longest known name win", () => {
    expectControl();
    expect(clean("then slash tidy notes.")).toBe("Then /tidy-notes.");
    expect(clean("then slash tidy.")).toBe("Then /tidy.");
  });

  it("knows the public harness commands without any dictionary entry", () => {
    expectControl();
    for (const name of ["clear", "compact", "config", "fast", "help", "init", "loop", "mcp", "model", "resume", "review"]) {
      expect(clean(`then you type slash ${name}.`)).toBe(`Then you type /${name}.`);
    }
  });
});

describe("a slash that is not a command keeps today's behaviour", () => {
  it("leaves an unknown name exactly as today (no guessing)", () => {
    expectControl();
    expect(clean("run slash frobnicate now.")).toBe("Run / frobnicate now.");
  });

  it("leaves joiners byte-identical", () => {
    expectControl();
    expect(clean("and slash or")).toBe("And / or");
    expect(clean("twenty four slash seven")).toBe("24/7");
    expect(clean("src slash rules engine dot ts")).toBe("Src / rules engine .ts");
  });

  it("leaves a command name that continues into a path as a path", () => {
    expectControl();
    expect(clean("src slash config slash index dot ts")).toBe("src/config/index .ts");
  });

  it("never loses or adds a word: only the spoken word 'slash' becomes '/'", () => {
    expectControl();
    const words = (text: string) =>
      (text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter((w) => w !== "slash").sort();
    for (const raw of [
      "And to tidy up, you just slash compact.",
      "should I run slash compact?",
      "Done. Slash compact now.",
      "say slash zephyr sweep slash tidy notes now",
      "first line\nslash compact.",
    ]) {
      expect(words(clean(raw))).toEqual(words(raw));
    }
  });
});
