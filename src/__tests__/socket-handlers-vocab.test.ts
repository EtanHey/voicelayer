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
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "Domica", variants: ["domekin"] },
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

  it("rejects aliases that collide with an existing canonical and explains why", () => {
    addPromptTerm("VoiceLayer", { path: vocabPath });

    const response = handleSocketCommand({
      cmd: "vocab_add",
      id: "vocab-add-collision",
      from: "voice layer",
      to: "VoiceBar",
    });

    expect(response).toEqual({
      type: "ack",
      command: "vocab_add",
      outcome: "reject",
      id: "vocab-add-collision",
      reason: "voice layer is already a canonical term: VoiceLayer",
    });
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "VoiceLayer", variants: [] },
    ]);
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
      entries: [{ canonical: "Domica", variants: ["domekin"] }],
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

  it("adds a prompt term through the socket handler", () => {
    const response = handleSocketCommand({
      cmd: "vocab_add_term",
      id: "term-add-1",
      term: "VoiceLayer",
    });

    expect(response).toEqual({
      type: "ack",
      command: "vocab_add_term",
      outcome: "accept",
      id: "term-add-1",
    });
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "VoiceLayer", variants: [] },
    ]);
  });

  it("rejects invalid prompt terms with a reject ack instead of throwing", () => {
    const response = handleSocketCommand({
      cmd: "vocab_add_term",
      id: "term-add-bad",
      term: "   ",
    });

    expect(response).toMatchObject({
      type: "ack",
      command: "vocab_add_term",
      outcome: "reject",
      id: "term-add-bad",
    });
  });

  it("rejects prompt terms that collide with an existing variant and explains why", () => {
    addAlias({ from: "voicelair", to: "VoiceLayer" }, { path: vocabPath });

    const response = handleSocketCommand({
      cmd: "vocab_add_term",
      id: "term-add-collision",
      term: "Voice Lair",
    });

    expect(response).toEqual({
      type: "ack",
      command: "vocab_add_term",
      outcome: "reject",
      id: "term-add-collision",
      reason: "Voice Lair is already a variant of VoiceLayer",
    });
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "VoiceLayer", variants: ["voicelair"] },
    ]);
  });

  it("removes a prompt term and returns noop when it is already absent", () => {
    addPromptTerm("VoiceLayer", { path: vocabPath });

    expect(
      handleSocketCommand({
        cmd: "vocab_remove_term",
        id: "term-remove-1",
        term: "voicelayer",
      }),
    ).toEqual({
      type: "ack",
      command: "vocab_remove_term",
      outcome: "accept",
      id: "term-remove-1",
    });
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([]);
    expect(
      handleSocketCommand({
        cmd: "vocab_remove_term",
        id: "term-remove-2",
        term: "voicelayer",
      }),
    ).toEqual({
      type: "ack",
      command: "vocab_remove_term",
      outcome: "noop",
      id: "term-remove-2",
      reason: "not found",
    });
  });
});
