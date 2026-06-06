import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import * as input from "../input";
import { handleSocketCommand } from "../socket-handlers";
import * as tts from "../tts";
import {
  addAlias,
  addPromptTerm,
  listVocabulary,
} from "../stt-vocabulary-store";

describe("socket vocabulary commands", () => {
  let tempDir = "";
  let vocabPath = "";
  let originalPath: string | undefined;
  let queueDepthSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "voicelayer-socket-vocab-"));
    vocabPath = join(tempDir, "stt-vocabulary.json");
    originalPath = process.env.QA_VOICE_STT_VOCABULARY_PATH;
    process.env.QA_VOICE_STT_VOCABULARY_PATH = vocabPath;
    queueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
    recordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "idle",
    );
  });

  afterEach(() => {
    queueDepthSpy.mockRestore();
    recordingStateSpy.mockRestore();
    if (originalPath === undefined) {
      delete process.env.QA_VOICE_STT_VOCABULARY_PATH;
    } else {
      process.env.QA_VOICE_STT_VOCABULARY_PATH = originalPath;
    }
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  });

  it("adds an alias through the socket handler and returns the existing ack shape", () => {
    const response = handleSocketCommand({
      cmd: "vocab_add",
      id: "vocab-add-1",
      from: "domekin",
      to: "Domica",
    });

    expect(response).toEqual({
      type: "ack",
      command: "vocab_add",
      outcome: "accept",
      id: "vocab-add-1",
    });
    expect(listVocabulary({ path: vocabPath }).aliases).toEqual([
      { from: "domekin", to: "Domica" },
    ]);
  });

  it("rejects unsafe aliases with a reject ack instead of throwing", () => {
    const response = handleSocketCommand({
      cmd: "vocab_add",
      id: "vocab-add-unsafe",
      from: "codecs",
      to: "Codex",
    });

    expect(response).toEqual({
      type: "ack",
      command: "vocab_add",
      outcome: "reject",
      id: "vocab-add-unsafe",
      reason: "unsafe alias source",
    });
  });

  it("lists the current vocabulary snapshot", () => {
    addPromptTerm("Domica", { path: vocabPath });
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });

    const response = handleSocketCommand({
      cmd: "vocab_list",
      id: "vocab-list-1",
    });

    expect(response).toEqual({
      type: "vocab_list",
      id: "vocab-list-1",
      updated_at: expect.any(String),
      prompt_terms: ["Domica"],
      aliases: [{ from: "domekin", to: "Domica" }],
    });
  });

  it("removes an alias and returns noop when it is already absent", () => {
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });

    expect(
      handleSocketCommand({
        cmd: "vocab_remove",
        id: "vocab-remove-1",
        from: "domekin",
      }),
    ).toEqual({
      type: "ack",
      command: "vocab_remove",
      outcome: "accept",
      id: "vocab-remove-1",
    });
    expect(
      handleSocketCommand({
        cmd: "vocab_remove",
        id: "vocab-remove-2",
        from: "domekin",
      }),
    ).toEqual({
      type: "ack",
      command: "vocab_remove",
      outcome: "noop",
      id: "vocab-remove-2",
      reason: "not found",
    });
  });
});
