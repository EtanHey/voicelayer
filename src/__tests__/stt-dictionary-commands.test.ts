/**
 * Lane c11-T8a: a command the user's dictionary produced is never glued to the
 * word before it by the path pass ("you just/compact." was delivered for
 * "you just slash compact."). Invented dictionary names only. Each test runs
 * the base-failing control, so every test fails on the base candidate.
 */
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { cleanupTranscriptionText } from "../stt-cleanup";

let directory = "";
let env: { QA_VOICE_STT_VOCABULARY_PATH: string; QA_VOICE_STT_COMMANDS_DIR: string };

beforeAll(() => {
  directory = mkdtempSync(join(TEST_TMP, "dict-cmds-"));
  env = { QA_VOICE_STT_VOCABULARY_PATH: join(directory, "vocabulary.json"), QA_VOICE_STT_COMMANDS_DIR: "" };
  writeFileSync(env.QA_VOICE_STT_VOCABULARY_PATH, JSON.stringify({
    entries: [
      { canonical: "/zephyr-sweep", variants: [] },
      { canonical: "/quill", variants: [] },
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
  it("keeps one space before a command that ends the sentence", () => {
    expectControl();
  });

  it("keeps the command before a question mark, a comma and the end of text", () => {
    expectControl();
    expect(clean("should I run slash quill?")).toBe("Should I run /quill?");
    expect(clean("run slash quill, then rest")).toBe("Run /quill, then rest");
    expect(clean("you just slash quill")).toBe("You just /quill");
  });

  it("starts the text or a line with no space before it", () => {
    expectControl();
    expect(clean("slash quill now.")).toBe("/quill now.");
    expect(clean("Done.\nslash quill now.")).toBe("Done.\n/quill now.");
  });

  it("keeps two commands in a row as two tokens with one space", () => {
    expectControl();
    expect(clean("then run slash zephyr sweep slash quill.")).toBe("Then run /zephyr-sweep /quill.");
  });

  // Literal outputs captured on origin/test/2.4-candidate-1110c (dac5f577).
  it("keeps paths, joiners and URLs byte-identical to the candidate", () => {
    expectControl();
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
      // A command followed by a non-command slash segment is a path.
      ["run slash quill slash index", "run/quill/index"],
      ["run slash quill slash zephyr sweep slash index", "run/quill/zephyr-sweep/index"],
      // A command directly after a path segment is a path.
      ["open src slash slash quill.", "Open src / /quill."],
      ["open src/ slash quill.", "Open src/ /quill."],
      ["edit notes.ts slash quill.", "Edit notes.ts/quill."],
      ["go to tilde slash quill.", "Go to ~/quill."],
    ] as const) {
      expect(clean(raw)).toBe(candidate);
    }
  });
});
