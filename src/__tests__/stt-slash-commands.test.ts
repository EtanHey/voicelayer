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
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { cleanupTranscriptionText } from "../stt-cleanup";
import {
  createSlashCommandNameCache,
  readSlashCommandRoot,
  readSlashCommandRootSync,
} from "../stt-slash-command-names";

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

/**
 * Round 2 (Codex review of round 1, 1 P1 + 3 P2).
 *
 * Lead ruling: dictionary entries convert as before; names of two or more
 * spoken words convert wherever spoken; a single-word name (the bundled public
 * commands, or a single-word skill folder) is a command only in command
 * context, and everywhere else the phrase keeps the candidate's bytes. The
 * literal control strings below were captured on origin/test/2.4-candidate-1110c
 * (dac5f577) with this file's fixture folder.
 */
describe("a single-word name is a command only in command context", () => {
  const positives: Array<[string, string, string]> = [
    ["start of the text", "slash help now.", "/help now."],
    ["start of a sentence", "Okay. Slash help, please.", "Okay. /help, please."],
    ["start of a line", "first line\nslash help", "First line\n/help"],
    ["after a comma", "first, slash model", "First, /model"],
    ["after a colon", "note: slash help", "Note: /help"],
    ["after a semicolon", "first; slash help", "First; /help"],
    ["after an opening parenthesis", "see (slash help) now", "See (/help) now"],
    ["after an opening quote", "he wrote \"slash help\" there", "He wrote \"/help\" there"],
    ["after another command token", "say slash zephyr sweep slash model now", "Say /zephyr-sweep /model now"],
    ["after the phrase 'the command'", "the command slash help", "The command /help"],
  ];
  for (const [context, raw, expected] of positives) {
    it(`converts ${context}`, () => {
      expect(clean(raw)).toBe(expected);
    });
  }

  // "say" and "typed" are also cue words, but the rules engine keeps a spoken
  // "slash" after them verbatim (it reads "I typed slash" as naming the word),
  // so for them the cue applies to a slash the recognizer wrote itself.
  const cues = ["run", "ran", "running", "use", "used", "using", "type", "typing", "do", "did", "try",
    "tried", "just", "then", "enter", "hit", "send", "invoke", "call", "with", "via"];
  it("converts directly after every cue word", () => {
    for (const cue of cues) expect(clean(`I ${cue} slash help now`), cue).toBe(`I ${cue} /help now`);
    for (const cue of [...cues, "say", "typed"]) {
      expect(clean(`I ${cue} / help now`), cue).toBe(`I ${cue} /help now`);
    }
  });

  it("leaves ordinary prose byte-identical to the candidate", () => {
    expect(clean("view slash model")).toBe("View / model");
    expect(clean("view slash model.")).toBe("view/model.");
    expect(clean("view slash help now")).toBe("View / help now");
    expect(clean("the review slash approval step")).toBe("The review / approval step");
    expect(clean("yes slash no")).toBe("Yes / no");
  });

  it("leaves spoken terminal paths byte-identical to the candidate", () => {
    expect(clean("src slash model slash index dot ts")).toBe("src/model/index .ts");
    expect(clean("cd slash help")).toBe("Cd / help");
    // A cue word does not turn a path into a command.
    expect(clean("run slash model slash index")).toBe("run/model/index");
  });

  it("treats a single-word skill folder like a public command", () => {
    expect(clean("view slash quill")).toBe("View / quill");
    expect(clean("run slash quill")).toBe("Run /quill");
  });

  it("converts a multi-word folder name wherever it is spoken", () => {
    expect(clean("view slash zephyr sweep")).toBe("View /zephyr-sweep");
  });

  it("keeps his own dictionary entries exactly as before", () => {
    const vocabulary = join(commandsDir, "dictionary.json");
    writeFileSync(vocabulary, JSON.stringify({ entries: [{ canonical: "/model", variants: [] }] }));
    const withDictionary = { ...env, QA_VOICE_STT_VOCABULARY_PATH: vocabulary };
    expect(cleanupTranscriptionText("view slash model", withDictionary)).toBe("View /model");
    expect(cleanupTranscriptionText("cd slash model", withDictionary)).toBe("Cd /model");
  });
});

describe("reading the skill folders never throws and never recurses", () => {
  const makeRoot = (label: string) => {
    const root = mkdtempSync(join(TEST_TMP, `slash-root-${label}-`));
    mkdirSync(join(root, "orbit-check"));
    writeFileSync(join(root, "orbit-check", "SKILL.md"), "# /orbit-check\n");
    return root;
  };

  it("survives symlinks to an ancestor folder", async () => {
    const root = makeRoot("cycle");
    // Two cycles: following them would visit 2^32 paths before ELOOP.
    symlinkSync(root, join(root, "loop-a"));
    symlinkSync(join(root, ".."), join(root, "loop-b"));
    mkdirSync(join(root, "nested"));
    symlinkSync(root, join(root, "nested", "back-up"));
    writeFileSync(join(root, "nested", "lantern.md"), "# /lantern\n");
    try {
      expect(readSlashCommandRootSync(root).sort()).toEqual(["/lantern", "/orbit-check"]);
      expect((await readSlashCommandRoot(root)).sort()).toEqual(["/lantern", "/orbit-check"]);
      expect(cleanupTranscriptionText("run slash orbit check.", { ...env, QA_VOICE_STT_COMMANDS_DIR: root }))
        .toBe("Run /orbit-check.");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("gives no names, and no error, for a missing root", () => {
    const missing = join(TEST_TMP, "slash-root-missing-never-created");
    expect(readSlashCommandRootSync(missing)).toEqual([]);
    expect(cleanupTranscriptionText("run slash orbit check.", { ...env, QA_VOICE_STT_COMMANDS_DIR: missing }))
      .toBe("Run / orbit check.");
  });

  it("gives no names from an unreadable root and still delivers the take", () => {
    const root = makeRoot("unreadable");
    chmodSync(root, 0o000);
    try {
      expect(() => readSlashCommandRootSync(root)).toThrow();
      const both = `${root}:${commandsDir}`;
      const unreadable = { ...env, QA_VOICE_STT_COMMANDS_DIR: both };
      expect(cleanupTranscriptionText("run slash orbit check.", unreadable)).toBe("Run / orbit check.");
      expect(cleanupTranscriptionText("run slash tidy notes.", unreadable)).toBe("Run /tidy-notes.");
    } finally {
      chmodSync(root, 0o755);
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("gives no names from a file where a folder is expected", () => {
    const file = join(TEST_TMP, `slash-root-file-${process.pid}.md`);
    writeFileSync(file, "not a folder\n");
    try {
      expect(cleanupTranscriptionText("run slash orbit check.", { ...env, QA_VOICE_STT_COMMANDS_DIR: file }))
        .toBe("Run / orbit check.");
    } finally {
      rmSync(file, { force: true });
    }
  });
});

describe("skill names are cached off the delivery path", () => {
  const harness = (options: { readRoot?: (root: string) => Promise<string[]> } = {}) => {
    let clock = 1_000_000;
    let mtime = 1;
    const calls = { sync: 0, async: 0, stat: 0 };
    let current = ["/orbit-check"];
    const cache = createSlashCommandNameCache({
      now: () => clock,
      rootMtimeMs: () => {
        calls.stat += 1;
        return mtime;
      },
      readRootSync: () => {
        calls.sync += 1;
        return [...current];
      },
      readRoot: options.readRoot ?? (async () => {
        calls.async += 1;
        return [...current];
      }),
    });
    return {
      cache,
      calls,
      advance: (ms: number) => { clock += ms; },
      touch: () => { mtime += 1; },
      setNames: (names: string[]) => { current = names; },
    };
  };

  it("reads a root once for two takes ten seconds apart", async () => {
    const h = harness();
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
    h.advance(10_000);
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
    await h.cache.settled();
    expect(h.calls).toMatchObject({ sync: 1, async: 0 });
  });

  it("refreshes once in the background when the root's mtime changes", async () => {
    const h = harness();
    h.cache.names(["/root"]);
    h.setNames(["/orbit-check", "/lantern"]);
    h.touch();
    // The take that notices the change still gets the previous set at once.
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
    await h.cache.settled();
    expect(h.calls).toMatchObject({ sync: 1, async: 1 });
    expect(h.cache.names(["/root"]).sort()).toEqual(["/lantern", "/orbit-check"]);
    await h.cache.settled();
    expect(h.calls.async).toBe(1);
  });

  it("refreshes after five minutes even without an mtime change", async () => {
    const h = harness();
    h.cache.names(["/root"]);
    h.advance(4 * 60_000);
    h.cache.names(["/root"]);
    await h.cache.settled();
    expect(h.calls.async).toBe(0);
    h.advance(60_000);
    h.cache.names(["/root"]);
    await h.cache.settled();
    expect(h.calls.async).toBe(1);
  });

  it("keeps the previous set when a refresh fails", async () => {
    const h = harness({ readRoot: async () => { throw new Error("EIO"); } });
    h.cache.names(["/root"]);
    h.touch();
    h.cache.names(["/root"]);
    await h.cache.settled();
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
  });

  it("never makes a take wait for a refresh in progress", () => {
    const h = harness({ readRoot: () => new Promise<string[]>(() => {}) });
    h.cache.names(["/root"]);
    h.touch();
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
    h.touch();
    expect(h.cache.names(["/root"])).toEqual(["/orbit-check"]);
  });

  it("never throws when the first read or the stat fails", () => {
    const cache = createSlashCommandNameCache({
      now: () => 0,
      rootMtimeMs: () => { throw new Error("EACCES"); },
      readRootSync: () => { throw new Error("EACCES"); },
      readRoot: async () => [],
    });
    expect(cache.names(["/root"])).toEqual([]);
    expect(cache.names(["/root"])).toEqual([]);
  });
});
