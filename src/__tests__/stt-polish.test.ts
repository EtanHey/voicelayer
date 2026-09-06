import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  getSTTPolishHealthTimeoutMs,
  getSTTPolishMode,
  getSTTPolishSocketTimeoutMs,
  getSTTPolishTimeoutMs,
  polishTranscriptionText,
} from "../stt-polish";
import * as sttPolish from "../stt-polish";

let TEST_DIR = "";
let TEST_SOCKET = "";
let TEST_LOG = "";

type MockPolishServer = {
  server: ReturnType<typeof Bun.listen>;
  received: Record<string, unknown>[];
  stop: () => void;
};

function createMockPolishServer(
  handler: (request: Record<string, unknown>) => Record<string, unknown> | null,
): MockPolishServer {
  const received: Record<string, unknown>[] = [];
  const server = Bun.listen<{ buffer: string }>({
    unix: TEST_SOCKET,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
      },
      data(socket, raw) {
        socket.data.buffer += raw.toString("utf-8");
        const lines = socket.data.buffer.split("\n");
        socket.data.buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const request = JSON.parse(line);
          received.push(request);
          const response = handler(request);
          if (response) {
            socket.write(`${JSON.stringify(response)}\n`);
          }
        }
      },
      close() {},
      error() {},
      drain() {},
    },
  });

  return {
    server,
    received,
    stop() {
      server.stop(true);
    },
  };
}

async function waitForFile(path: string): Promise<void> {
  for (let i = 0; i < 50; i++) {
    if (existsSync(path)) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`Timed out waiting for ${path}`);
}

function warmPolishEndpointForTest() {
  const warmPolishEndpoint = (
    sttPolish as {
      warmPolishEndpoint?: (env: Record<string, string | undefined>) => Promise<{
        status: string;
        latencyMs: number;
        error?: string;
      }>;
    }
  ).warmPolishEndpoint;
  expect(typeof warmPolishEndpoint).toBe("function");
  if (!warmPolishEndpoint) {
    throw new Error("warmPolishEndpoint export missing");
  }
  return warmPolishEndpoint;
}

describe("stt-polish", () => {
  let server: MockPolishServer | null = null;

  beforeEach(() => {
    TEST_DIR = mkdtempSync(join(tmpdir(), "voicelayer-polish-"));
    TEST_SOCKET = join(TEST_DIR, "polish.sock");
    TEST_LOG = join(TEST_DIR, "polish.jsonl");
  });

  afterEach(async () => {
    server?.stop();
    server = null;
    await new Promise((resolve) => setTimeout(resolve, 50));
    if (TEST_DIR) {
      rmSync(TEST_DIR, { recursive: true, force: true });
      TEST_DIR = "";
      TEST_SOCKET = "";
      TEST_LOG = "";
    }
  });

  it("defaults to on for production dictation", () => {
    expect(getSTTPolishMode({})).toBe("on");
  });

  it("uses a patient default health timeout and a generous request timeout", () => {
    expect(getSTTPolishHealthTimeoutMs({})).toBeGreaterThanOrEqual(1_200);
    expect(getSTTPolishHealthTimeoutMs({})).toBeLessThanOrEqual(1_500);
    expect(getSTTPolishTimeoutMs({})).toBeGreaterThanOrEqual(18_000);
    expect(getSTTPolishSocketTimeoutMs({})).toBeLessThanOrEqual(1_500);
  });

  it("can be explicitly disabled and preserves cleaned text", async () => {
    const result = await polishTranscriptionText({
      rawText: "brain layer",
      cleanedText: "BrainLayer",
      env: { QA_VOICE_STT_POLISH: "off" },
    });

    expect(result).toMatchObject({
      text: "BrainLayer",
      mode: "off",
      status: "skipped",
      changed: false,
    });
  });

  it("uses polished text in on mode when the local socket responds", async () => {
    server = createMockPolishServer(() => ({
      text: "Also, do /whats-new and output that as your summary.",
    }));

    const result = await polishTranscriptionText({
      rawText: "also, do / what's new and output that as your summary",
      cleanedText: "Also, do / what's new and output that as your summary",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Also, do /whats-new and output that as your summary.",
      mode: "on",
      status: "applied",
      changed: true,
    });
    expect(server.received[0]).toMatchObject({
      raw_text: "also, do / what's new and output that as your summary",
      cleaned_text: "Also, do / what's new and output that as your summary",
      surface: "dictation",
    });
  });

  it("shadow mode never changes the text, even when boundaries demote", async () => {
    // Macroscope round 1: shadow observes and must not touch what Etan gets.
    // The demotion still has to reach the row.
    server = createMockPolishServer(() => ({
      text: "Alpha bravo charlie. I guess foxtrot golf hotel.",
    }));

    const cleanedText = "Alpha bravo charlie. I guess foxtrot golf hotel.";
    const result = await polishTranscriptionText({
      rawText: "alpha bravo charlie i guess foxtrot golf hotel",
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "shadow",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        VOICELAYER_STT_SMART_BOUNDARIES: "1",
      },
      boundaryContext: {
        segments: [
          {
            text: "alpha bravo charlie i guess foxtrot golf hotel",
            startS: 0,
            endS: 8,
          },
        ],
        pauses: [{ startS: 8, endS: 9 }],
      },
    });

    expect(result.text).toBe(cleanedText);
    expect(result.changed).toBe(false);
    expect(result.boundaryDemotions?.[0]).toMatchObject({
      word: "charlie",
      reason: "continues-clause",
    });
    await waitForFile(TEST_LOG);
    const logRow = JSON.parse(readFileSync(TEST_LOG, "utf8").trim());
    expect(logRow.final_text).toBe(cleanedText);
    expect(logRow.boundary_demotions?.[0]?.word).toBe("charlie");
  });

  it("applies the demotion when polish is ON, not shadow", async () => {
    server = createMockPolishServer(() => ({
      text: "Alpha bravo charlie. I guess foxtrot golf hotel.",
    }));

    const result = await polishTranscriptionText({
      rawText: "alpha bravo charlie i guess foxtrot golf hotel",
      cleanedText: "Alpha bravo charlie I guess foxtrot golf hotel.",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        VOICELAYER_STT_SMART_BOUNDARIES: "1",
      },
      boundaryContext: {
        segments: [
          {
            text: "alpha bravo charlie i guess foxtrot golf hotel",
            startS: 0,
            endS: 8,
          },
        ],
        pauses: [{ startS: 8, endS: 9 }],
      },
    });

    expect(result.text).toContain("charlie, I guess");
  });

  it("a boundary demotion does not count as the model having changed anything", async () => {
    // Macroscope round 1: `changed` fed the no-op retry, so a demotion made an
    // unchanged polish response look like a real edit and the punctuation-repair
    // retry was skipped. The retry must judge the model, not this stage.
    const cleanedText =
      "Alpha bravo charlie. I guess foxtrot golf hotel india juliett kilo lima mike november.";
    const result = await polishTranscriptionText({
      rawText: cleanedText.toLowerCase(),
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        VOICELAYER_STT_SMART_BOUNDARIES: "1",
      },
      boundaryContext: {
        segments: [
          {
            text: "alpha bravo charlie i guess foxtrot golf hotel india juliett kilo lima mike november",
            startS: 0,
            endS: 14,
          },
        ],
        pauses: [{ startS: 14, endS: 15 }],
      },
    });

    // The demotion landed...
    expect(result.text).toContain("charlie, I guess");
    // ...but it is not evidence the model changed its response.
    expect(result.candidateChanged).toBe(false);
    expect(result.changed).toBe(true);
  });

  it("keeps cleaned text in shadow mode and logs the candidate", async () => {
    server = createMockPolishServer(() => ({
      text: "Also, do /whats-new and output that as your summary.",
    }));

    const result = await polishTranscriptionText({
      rawText: "also, do / what's new and output that as your summary",
      cleanedText: "Also, do / what's new and output that as your summary",
      env: {
        QA_VOICE_STT_POLISH: "shadow",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Also, do / what's new and output that as your summary",
      polishedText: "Also, do /whats-new and output that as your summary.",
      mode: "shadow",
      status: "shadowed",
      changed: false,
    });
    await waitForFile(TEST_LOG);
    const logRow = JSON.parse(readFileSync(TEST_LOG, "utf8").trim());
    expect(logRow).toMatchObject({
      mode: "shadow",
      status: "shadowed",
      raw_text: "also, do / what's new and output that as your summary",
      cleaned_text: "Also, do / what's new and output that as your summary",
      polished_text: "Also, do /whats-new and output that as your summary.",
      final_text: "Also, do / what's new and output that as your summary",
    });
  });

  it("falls back to cleaned text when the polish socket is missing", async () => {
    const result = await polishTranscriptionText({
      rawText: "brain layer",
      cleanedText: "BrainLayer",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "BrainLayer",
      mode: "on",
      status: "unavailable",
      changed: false,
    });
  });

  it("falls back quickly when the polish socket times out", async () => {
    server = createMockPolishServer(() => null);

    const startedAt = performance.now();
    const result = await polishTranscriptionText({
      rawText: "brain layer",
      cleanedText: "BrainLayer",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_TIMEOUT_MS: "10",
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(performance.now() - startedAt).toBeLessThan(250);
    expect(result.text).toBe("BrainLayer");
    expect(result.status).toBe("failed");
    expect(result.error).toContain("timed out");
  });

  it("floors every active on-mode non-applied fallback status", async () => {
    const cleanedText =
      "so i was thinking about the whole voice layer pipeline and how the polish " +
      "step is supposed to add punctuation but sometimes it just does not and then " +
      "you end up with this giant wall of text that has no periods no commas nothing " +
      "and it is really hard to read especially when the dictation is long like this " +
      "one where i just keep talking and talking without ever stopping to breathe or " +
      "add any kind of structure to what i am saying which is exactly the failure mode";
    server = createMockPolishServer(() => ({
      text: `Raw Whisper text: ${cleanedText}`,
    }));
    const rejected = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });
    server.stop();
    server = null;

    const unavailable = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: `${TEST_SOCKET}.missing`,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    TEST_SOCKET = join(TEST_DIR, "timeout.sock");
    server = createMockPolishServer(() => null);
    const failed = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_TIMEOUT_MS: "10",
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    const results = [rejected, unavailable, failed];
    expect(results.map((result) => result.status)).toEqual([
      "rejected",
      "unavailable",
      "failed",
    ]);
    for (const result of results) {
      expect(result.text.endsWith(".")).toBe(true);
      expect(result.polished).toBe(false);
    }
  });

  it("rejects polish candidates that drop substantial content in on mode", async () => {
    server = createMockPolishServer(() => ({
      text: "BrainLayer will be responsive.",
    }));

    const cleanedText =
      "For fuck's sake. If BrainLayer hybrid is done, then it can just merge. Come on. I want to review the PR later. We need to make sure that they're all synced. BrainLayer will be responsive and usable?";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "BrainLayer will be responsive.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("dropped");
  });

  it("projects punctuation from a high-overlap rejected candidate without adopting drifted words", async () => {
    const cleanedText =
      "please compare the settings on this mac with /weave before you change anything then check the microphone permissions and the automation entries carefully because the two machines should match";
    const candidate =
      "Please compare the settings on this Mac with /wave before you change anything. Then check the microphone permissions and the automation entries carefully, because the two machines should match.";
    server = createMockPolishServer(() => ({ text: candidate }));

    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text:
        "please compare the settings on this mac with /weave before you change anything. then check the microphone permissions and the automation entries carefully, because the two machines should match.",
      polishedText: candidate,
      status: "rejected",
      changed: true,
    });
    expect(result.text).not.toContain("/wave");
    expect(result.error).toContain("protected tokens");
  });

  it("uses surrounding sequence to align punctuation after repeated words", async () => {
    const cleanedText =
      "please review the complete recording carefully with the team and mark this point while we discuss details and mark this point then continue with /weave and finish the final report for tomorrow morning without changing any other instruction and send the summary to the lead after all required checks finish";
    const candidate =
      "Please review the complete recording carefully with the team and mark this point. Then continue with /wave and finish the final report for tomorrow morning without changing any other instruction and send the summary to the lead after all required checks finish.";
    server = createMockPolishServer(() => ({ text: candidate }));

    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text:
        "please review the complete recording carefully with the team and mark this point while we discuss details and mark this point. then continue with /weave and finish the final report for tomorrow morning without changing any other instruction and send the summary to the lead after all required checks finish.",
      status: "rejected",
      changed: true,
    });
    expect(result.text).not.toContain("mark this point. while we discuss");
  });

  it("recognizes projected terminal punctuation before a closing quote", async () => {
    const cleanedText =
      'the lead said "please compare the complete recording with /weave and keep every original instruction exactly as spoken before you send the final summary tonight"';
    const candidate =
      'The lead said, "Please compare the complete recording with /wave and keep every original instruction exactly as spoken before you send the final summary tonight."';
    server = createMockPolishServer(() => ({ text: candidate }));

    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text:
        'the lead said, "please compare the complete recording with /weave and keep every original instruction exactly as spoken before you send the final summary tonight."',
      status: "rejected",
      changed: true,
    });
    expect(result.text.endsWith('".')).toBe(false);
  });

  it("rejects same-length long rewrites in on mode", async () => {
    server = createMockPolishServer(() => ({
      text: "After merge, the app is faster, cleaner, safer, simpler, stable, ready, reviewed, documented, tested, and deployable without me reading the pull request again today safely.",
    }));

    const cleanedText =
      "For fuck's sake. If BrainLayer hybrid is done, then it can just merge. Come on. I do not want to look at the PR. We need to make sure that they are all synced.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("changed too much text");
  });

  it("rejects prompt-echo polish responses instead of pasting instructions", async () => {
    server = createMockPolishServer(() => ({
      text: "Raw Whisper text:\nbrain layer\n\nVoiceLayer cleaned text to fix:\nBrainLayer",
    }));

    const result = await polishTranscriptionText({
      rawText: "brain layer",
      cleanedText: "BrainLayer",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "BrainLayer",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("echoed");
  });

  it("rejects unrelated short polish candidates in on mode", async () => {
    server = createMockPolishServer(() => ({
      text: "Delete the handleSubmit function.",
    }));

    const result = await polishTranscriptionText({
      rawText: "brain layer",
      cleanedText: "BrainLayer",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "BrainLayer",
      polishedText: "Delete the handleSubmit function.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("invented code identifier");
  });

  it("rejects polish candidates that invent code-style identifiers", async () => {
    server = createMockPolishServer(() => ({
      text: "By the way, is BrainSearch or BrainInjecting helping?",
    }));

    const cleanedText = "By the way, is brain search or brain injecting helping?";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "By the way, is BrainSearch or BrainInjecting helping?",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("invented code identifier");
  });

  it("allows known vocabulary code identifiers from dictation-finalizer examples", async () => {
    server = createMockPolishServer(() => ({
      text: "תרים את ה-handleSocketCommand",
    }));

    const cleanedText = "תרים את ה handle socket command";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "תרים את ה-handleSocketCommand",
      status: "applied",
      changed: true,
    });
  });

  it("allows known cleaned vocabulary identifiers when polish adds sentence punctuation", async () => {
    const polished =
      "Wait, what? Work with a cmuxlayerCodex. When you eval, only spawn cursors as dummies.";
    server = createMockPolishServer(() => ({
      text: polished,
    }));

    const cleanedText =
      "Wait what work with a cmuxlayerCodex when you eval only spawn cursors as dummies.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: polished,
      status: "applied",
      changed: true,
    });
  });

  it("rejects polish candidates that remove negation from short dictation", async () => {
    server = createMockPolishServer(() => ({
      text: "I want to look",
    }));

    const result = await polishTranscriptionText({
      rawText: "i don't want to look",
      cleanedText: "I don't want to look",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "I don't want to look",
      polishedText: "I want to look",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("changed negation");
  });

  it("rejects polish candidates that remove code punctuation", async () => {
    server = createMockPolishServer(() => ({
      text: "Use rm rf tmp and then run whats new.",
    }));

    const cleanedText = "Use rm -rf /tmp and then run /whats-new.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "Use rm rf tmp and then run whats new.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("removed code punctuation");
  });

  it("allows slash command spacing cleanup when the slash is preserved", async () => {
    server = createMockPolishServer(() => ({
      text: "Also, do /whats-new and output that as your summary.",
    }));

    const cleanedText = "Also, do / what's new and output that as your summary.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Also, do /whats-new and output that as your summary.",
      status: "applied",
      changed: true,
    });
  });

  it("allows explicit self-correction cleanup in dictation finalizer mode", async () => {
    server = createMockPolishServer(() => ({
      text: "Okay, let's do Claude deep research.",
    }));

    const cleanedText = "Okay, let's do Gemini deep, well no, Claude deep research.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Okay, let's do Claude deep research.",
      status: "applied",
      changed: true,
    });
  });

  it("allows explicit self-correction cleanup when Whisper punctuates the cue", async () => {
    server = createMockPolishServer(() => ({
      text: "Okay, let's do Claude Deep Research.",
    }));

    const cleanedText =
      "Okay, let's do Gemini Deep, well, no, Claude Deep Research.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Okay, let's do Claude Deep Research.",
      status: "applied",
      changed: true,
    });
  });

  it("allows grammatical article agreement in punctuation polish containing a correction cue", async () => {
    const polished =
      "I don't see, oh okay, now I see: codex lead austerity — should that one " +
      "be pushed to an ultra-ultra effort? Maybe also, I don't think you answered: " +
      "do you need me to make a codex effort ultra for you or not? Shit, look at this bs bs.";
    server = createMockPolishServer(() => ({ text: polished }));

    const cleanedText =
      "I don't see oh okay now I see codex lead austerity should that 1 be pushed " +
      "to a ultra ultra effort maybe also I don't think you answered do you need me " +
      "to make you or sorry to make a codex effort ultra for you or not shit look at this bs bs.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: polished,
      status: "applied",
      polished: true,
    });
  });

  it("allows real correction-cue collapse that removes the rejected phrase and its no/not scaffolding", async () => {
    server = createMockPolishServer(() => ({
      text: "Okay, let's do a Gemini deep research.",
    }));

    const result = await polishTranscriptionText({
      rawText: "okay let's do a Claude well no not Claude let's do a Gemini deep research",
      cleanedText:
        "Okay let's do a Claude well no not Claude let's do a Gemini deep research.",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Okay, let's do a Gemini deep research.",
      status: "applied",
      changed: true,
    });
  });

  it("allows punctuation polish for non-correction text that preserves existing negation meaning", async () => {
    const polished =
      "Yeah, it seems like quotes are not happening anymore, where in the past they did happen generally. There's no numbering and there's no corrections. The .at file seems to be one of the only things that's fixed; other than punctuation, it seems to work now pretty reliably.";
    server = createMockPolishServer(() => ({ text: polished }));

    const cleanedText =
      "Yeah, it seems like quotes are not happening anymore, where in the past they did happen generally. There's 0 numbering and there's no corrections. The .at file seems to be 1 of the only things that's fixed other than punctuation as well seems to work now pretty reliably.";
    const result = await polishTranscriptionText({
      rawText:
        "Yeah, it seems like quotes are not happening anymore, where in the past they did happen generally. There's zero numbering and there's no corrections. The .at file seems to be one of the only things that's fixed other than punctuation as well seems to work now pretty reliably.",
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: polished,
      status: "applied",
      changed: true,
    });
  });

  it("collapses a real self-correction cue even when the polish model returns the candidate unchanged", async () => {
    server = createMockPolishServer((request) => ({
      text: String(request.cleaned_text),
    }));

    const result = await polishTranscriptionText({
      rawText: "Okay, let's do a clawed deep, well, Gemini deep research.",
      cleanedText: "Okay, let's do a Claude deep, well, Gemini deep research.",
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Okay, let's do Gemini deep research.",
      status: "applied",
      changed: true,
    });
  });

  it("rejects self-correction rewrites that introduce new content even with explicit cues", async () => {
    server = createMockPolishServer(() => ({
      text: "Please run tests before production release.",
    }));

    const cleanedText =
      "Please deploy to staging, well no, run tests before merge.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "Please run tests before production release.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("introduced new content");
  });

  it("allows explicit spoken-list restructuring into numbered markdown", async () => {
    server = createMockPolishServer(() => ({
      text: "Okay:\n1. I want to do x, y, z.\n2. I want to do the other thing.\n3. I want to do this, that, and this.",
    }));

    const cleanedText =
      "Or if I say, okay, first of all, I want to do x, y, z, and then second of all, I want to do the other thing, and then third of all, I want to do this, that, and this.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Okay:\n1. I want to do x, y, z.\n2. I want to do the other thing.\n3. I want to do this, that, and this.",
      status: "applied",
      changed: true,
    });
  });

  it("rejects polish candidates that swap protected slash tokens", async () => {
    server = createMockPolishServer(() => ({
      text: "Run /deploy after the tests pass.",
    }));

    const cleanedText = "Run /commit after the tests pass.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "Run /deploy after the tests pass.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("changed protected tokens");
  });

  it("rejects polish candidates that introduce a slash command", async () => {
    server = createMockPolishServer(() => ({
      text: "Run /commit after tests.",
    }));

    const cleanedText = "Run commit after tests.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "Run /commit after tests.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("changed protected tokens");
  });

  it("rejects polish candidates that alter numeric instructions", async () => {
    server = createMockPolishServer(() => ({
      text: "Delete 30 files before 6pm.",
    }));

    const cleanedText = "Delete 3 files before 6pm.";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: cleanedText,
      polishedText: "Delete 30 files before 6pm.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("changed protected tokens");
  });

  it("allows punctuation repair when digit tokens are only written as equivalent number words", async () => {
    server = createMockPolishServer(() => ({
      text: "So wait, what do you mean follow-up backlog? Why did you all not do it well? It seems like we've evaled this very good, and I'm now seeing the golemsClaude on your right. Three minor non-blocking gaps: failure recur, record path untested, cleanup skip is silent exit 0 with no Telegram warning, no boundary test for adjacency window edge. Well, I mean again, this should have been more compounding. I want this to be fucking hard, fucking rock solid. Can you get your own ID, your own Claude session ID, and send that to me?",
    }));

    const cleanedText =
      "So wait what do you mean follow up backlog why did you all not do it well it seems like we've evaled this very good and I'm now seeing the golemsClaude on your right 3 minor non-blocking gaps failure recur record path untested cleanup skip is silent exit 0 with no Telegram warning no boundary test for adjacency window edge well I mean again this should have been more compounding I want this to be fucking hard fucking rock solid can you get your own id your own Claude session id and send that to me";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "So wait, what do you mean follow-up backlog? Why did you all not do it well? It seems like we've evaled this very good, and I'm now seeing the golemsClaude on your right. Three minor non-blocking gaps: failure recur, record path untested, cleanup skip is silent exit 0 with no Telegram warning, no boundary test for adjacency window edge. Well, I mean again, this should have been more compounding. I want this to be fucking hard, fucking rock solid. Can you get your own ID, your own Claude session ID, and send that to me?",
      status: "applied",
      changed: true,
    });
  });

  it("allows punctuation repair when multi-digit tokens are written as equivalent number words", async () => {
    server = createMockPolishServer(() => ({
      text: "Review forty two dashboard files before 6pm.",
    }));

    const cleanedText = "Review 42 dashboard files before 6pm";
    const result = await polishTranscriptionText({
      rawText: cleanedText,
      cleanedText,
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_SOCKET: TEST_SOCKET,
        QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
      },
    });

    expect(result).toMatchObject({
      text: "Review forty two dashboard files before 6pm.",
      status: "applied",
      changed: true,
    });
  });

  it("calls an OpenAI-compatible local polish endpoint when configured", async () => {
    const requests: Record<string, unknown>[] = [];
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [
            {
              message: {
                content: "Also, do /whats-new and output that as your summary.",
              },
            },
          ],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: "also, do / what's new and output that as your summary",
        cleanedText: "Also, do / what's new and output that as your summary",
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result.text).toBe(
        "Also, do /whats-new and output that as your summary.",
      );
      expect(requests).toHaveLength(1);
      expect(requests[0]).toMatchObject({
        model: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        temperature: 0,
        top_p: 1,
        max_tokens: 512,
        repetition_penalty: 0,
        stream: false,
      });
      const messages = requests[0].messages as Array<{
        role: string;
        content: string;
      }>;
      expect(messages[0].role).toBe("system");
      expect(messages[0].content).toContain("dictation finalizer");
      expect(messages[0].content).toContain("well no");
      expect(messages[0].content).toContain("numbered markdown lists");
      expect(messages[0].content).toContain("ANY ordinal sequence");
      expect(messages[0].content).toContain("Input: So first of all");
      expect(messages[0].content).toContain("third, I'm very frustrated");
      expect(messages[0].content).toContain("not Claude let's do a Gemini");
      expect(messages[0].content).toContain("Claude deep, well, Gemini");
      expect(messages[0].content).toContain("did X");
      expect(messages[0].content).toContain("I just went to the supermarket");
      expect(messages[0].content).toContain(".at");
      expect(messages[0].content).toContain("Preserve Hebrew");
      expect(messages[0].content).not.toContain(
        "If unsure, return the input unchanged",
      );
      expect(messages[1].content).toContain(
        "Also, do / what's new and output that as your summary",
      );
    } finally {
      server.stop(true);
    }
  });

  it("retries rejected truncated HTTP polish for long punctuation-poor dictation", async () => {
    const cleanedText =
      "please compare the settings on the first mac with the settings on this mac and make sure the permissions line up before you change anything i want the accessibility entries the microphone entries the automation entries and the full disk access entries checked carefully because the two machines should mostly match and the only real difference should be how the brain layer data is separated for that project also look for stale duplicates and tell me which entries are safe to remove after you verify the app versions";
    const polishedText =
      "Please compare the settings on the first Mac with the settings on this Mac, and make sure the permissions line up before you change anything. I want the accessibility entries, the microphone entries, the automation entries, and the full disk access entries checked carefully, because the two machines should mostly match. The only real difference should be how the BrainLayer data is separated for that project. Also, look for stale duplicates and tell me which entries are safe to remove after you verify the app versions.";
    const responses = [
      "Please compare the settings on the first Mac with the settings on this Mac. I want the accessibility entries, the microphone entries, and",
      polishedText,
    ];
    const requests: Record<string, unknown>[] = [];
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [
            {
              message: {
                content: responses.shift(),
              },
            },
          ],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: polishedText,
        status: "applied",
        changed: true,
        retried: true,
      });
      expect(requests).toHaveLength(2);
      expect(requests[0].max_tokens).toBeGreaterThanOrEqual(512);
      expect(requests[1].max_tokens).toBeGreaterThanOrEqual(512);
      const retryMessages = requests[1].messages as Array<{
        role: string;
        content: string;
      }>;
      expect(retryMessages[0].content).toContain("previous response was rejected");
      expect(retryMessages[0].content).toContain("full corrected text");
    } finally {
      server.stop(true);
    }
  });

  it("scales HTTP polish completion budget above the floor for long dictation", async () => {
    const requests: Record<string, unknown>[] = [];
    const cleanedText = Array.from(
      { length: 260 },
      (_, index) => `word${index}`,
    ).join(" ");
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [{ message: { content: cleanedText } }],
        });
      },
    });

    try {
      await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(requests).toHaveLength(3);
      expect(requests[0].max_tokens).toBeGreaterThan(512);
      expect(requests[0].max_tokens).toBeLessThanOrEqual(4096);
      expect(requests[1].max_tokens).toBe(requests[0].max_tokens);
      expect(requests[2].max_tokens).toBe(requests[0].max_tokens);
    } finally {
      server.stop(true);
    }
  });

  it("waits for a reachable slow HTTP polish completion instead of falling back", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        await new Promise((resolve) => setTimeout(resolve, 2_100));
        return Response.json({
          choices: [
            {
              message: {
                content: "Why did it do that? I am confused.",
              },
            },
          ],
        });
      },
    });

    try {
      const startedAt = performance.now();
      const result = await polishTranscriptionText({
        rawText: "why did it do that i am confused",
        cleanedText: "why did it do that i am confused",
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(performance.now() - startedAt).toBeGreaterThanOrEqual(2_000);
      expect(result).toMatchObject({
        text: "Why did it do that? I am confused.",
        status: "applied",
        changed: true,
      });
    } finally {
      server.stop(true);
    }
  });

  it("skips an unreachable HTTP polish endpoint after a fast health probe", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const startedAt = performance.now();
      const result = await polishTranscriptionText({
        rawText: "brain layer",
        cleanedText: "BrainLayer",
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(performance.now() - startedAt).toBeLessThan(500);
      expect(result).toMatchObject({
        text: "BrainLayer",
        status: "failed",
        changed: false,
        polished: false,
      });
      expect(result.error).toContain("health");
      expect(result.reason).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("adds a deterministic punctuation floor when HTTP polish health times out on a long run-on", async () => {
    const cleanedText =
      "did your skill weave lead finish did it do a full weave did you consume it what happened here on your watch because i need the answer now";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: "Did your skill weave lead finish? Did it do a full weave? Did you consume it? What happened here on your watch because i need the answer now?",
        status: "failed",
        changed: true,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("keeps shadow mode output unchanged when HTTP polish health fails on a question run-on", async () => {
    const cleanedText =
      "did your skill weave lead finish did it do a full weave did you consume it what happened here on your watch because i need the answer now";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "shadow",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        mode: "shadow",
        status: "failed",
        changed: false,
        polished: false,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("does not force-split a statement-phrased run-on when HTTP polish is unavailable", async () => {
    const cleanedText =
      "we finished the pull request and deployed it to staging after every required test passed so the team can review everything tomorrow morning";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        status: "failed",
        changed: false,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("adds a terminal punctuation floor to a long single-narrative fallback", async () => {
    const cleanedText =
      "so i was thinking about the whole voice layer pipeline and how the polish " +
      "step is supposed to add punctuation but sometimes it just does not and then " +
      "you end up with this giant wall of text that has no periods no commas nothing " +
      "and it is really hard to read especially when the dictation is long like this " +
      "one where i just keep talking and talking without ever stopping to breathe or " +
      "add any kind of structure to what i am saying which is exactly the failure mode";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: `${cleanedText}.`,
        status: "failed",
        changed: true,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("does not fragment embedded question clauses when HTTP polish is unavailable", async () => {
    const cleanedText =
      "can you tell me what you did and how you did it because i need to know now for the report tomorrow";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        status: "failed",
        changed: false,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("does not fragment auxiliary inversion inside embedded wh-clauses", async () => {
    const cleanedText =
      "what do i need to know about how do i configure this and why does it fail because the report is due tomorrow and the team needs an answer";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        status: "failed",
        changed: false,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("does not fragment proper-name subjects inside embedded wh-clauses", async () => {
    const cleanedText =
      "can you explain what Alice did the first time and how Bob did the rollout and why Carol did the final check because the report is due tomorrow and the team needs answers";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        status: "failed",
        changed: false,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("recognizes auxiliary question boundaries when HTTP polish is unavailable", async () => {
    const cleanedText =
      "did you finish the pull request do you know whether tests passed is it ready for the whole team to review right now";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: "Did you finish the pull request? Do you know whether tests passed? Is it ready for the whole team to review right now?",
        status: "failed",
        changed: true,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("recognizes proper-name subjects at auxiliary question boundaries", async () => {
    const cleanedText =
      "did you see the deployment today did Alice restart the server after lunch did Bob verify the service afterward";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: "Did you see the deployment today? Did Alice restart the server after lunch? Did Bob verify the service afterward?",
        status: "failed",
        changed: true,
      });
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("does not split a declarative auxiliary between named questions", async () => {
    const cleanedText =
      "did Alice restart the server today did Bob verify the deployment after lunch because the report is due tomorrow did Carol notify the whole team afterward";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: "Did Alice restart the server today? Did Bob verify the deployment after lunch because the report is due tomorrow? Did Carol notify the whole team afterward?",
        status: "failed",
        changed: true,
      });
      expect(result.text).not.toContain("report? Is due");
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("removes a trailing comma before adding fallback question punctuation", async () => {
    const cleanedText =
      "did your skill weave lead finish, did it do a full weave did you consume it what happened here on your watch because i need the answer right now";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: "Did your skill weave lead finish? Did it do a full weave? Did you consume it? What happened here on your watch because i need the answer right now?",
        status: "failed",
        changed: true,
      });
      expect(result.text).not.toContain(",?");
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("preserves a statement-phrased right tag question when HTTP polish is unavailable", async () => {
    const cleanedText =
      "we finished the pull request and deployed it to staging after every required test passed and the team reviewed all the logs right?";
    const server = Bun.serve({
      port: 0,
      fetch: async () => {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        return Response.json({ data: [] });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "100",
          QA_VOICE_STT_POLISH_TIMEOUT_MS: "3000",
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result).toMatchObject({
        text: cleanedText,
        status: "failed",
        changed: false,
      });
      expect(result.text.endsWith("right?")).toBe(true);
      expect(result.error).toContain("health");
    } finally {
      server.stop(true);
    }
  });

  it("preserves endpoint query parameters on the HTTP health probe", async () => {
    let healthSearch = "";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          healthSearch = url.search;
          return Response.json({ data: [] });
        }
        return Response.json({
          choices: [
            {
              message: {
                content: "Why did it do that? I am confused.",
              },
            },
          ],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: "why did it do that i am confused",
        cleanedText: "why did it do that i am confused",
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions?api_key=test-key&route=local`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(healthSearch).toBe("?api_key=test-key&route=local");
      expect(result).toMatchObject({
        text: "Why did it do that? I am confused.",
        status: "applied",
      });
    } finally {
      server.stop(true);
    }
  });

  it("warms the HTTP polish endpoint with a health probe and tiny completion", async () => {
    const requests: Array<{ method: string; pathname: string; body?: Record<string, unknown> }> =
      [];
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        const entry: { method: string; pathname: string; body?: Record<string, unknown> } = {
          method: request.method,
          pathname: url.pathname,
        };
        if (request.method !== "GET") {
          entry.body = (await request.json()) as Record<string, unknown>;
        }
        requests.push(entry);

        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        return Response.json({
          choices: [{ message: { content: "." } }],
        });
      },
    });

    try {
      const result = await warmPolishEndpointForTest()({
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      });

      expect(result.status).toBe("warmed");
      expect(result.latencyMs).toBeGreaterThanOrEqual(0);
      expect(requests.map((request) => [request.method, request.pathname])).toEqual([
        ["GET", "/v1/models"],
        ["POST", "/v1/chat/completions"],
      ]);
      expect(requests[1].body).toMatchObject({
        max_tokens: 1,
        stream: false,
      });
    } finally {
      server.stop(true);
    }
  });

  it("skips polish warmup when disabled", async () => {
    const result = await warmPolishEndpointForTest()({
      VOICELAYER_STT_POLISH_WARMUP: "off",
      QA_VOICE_STT_POLISH_ENDPOINT: "http://127.0.0.1:1/v1/chat/completions",
    });

    expect(result).toMatchObject({
      status: "skipped",
    });
  });

  it("returns failed status instead of throwing when warmup cannot reach the endpoint", async () => {
    const result = await warmPolishEndpointForTest()({
      QA_VOICE_STT_POLISH_ENDPOINT: "http://127.0.0.1:1/v1/chat/completions",
      QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS: "20",
      VOICELAYER_STT_POLISH_WARMUP_TIMEOUT_MS: "20",
    });

    expect(result.status).toBe("failed");
    expect(result.error).toContain("polish health check failed");
  });

  it("returns failed status when warmup receives an invalid completion payload", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        return Response.json({ choices: [{ message: {} }] });
      },
    });

    try {
      const result = await warmPolishEndpointForTest()({
        QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      });

      expect(result.status).toBe("failed");
      expect(result.error).toContain("missing message content");
    } finally {
      server.stop(true);
    }
  });

  it("retries once when HTTP polish no-ops on a long low-punctuation run-on", async () => {
    const requests: Record<string, unknown>[] = [];
    const cleanedText =
      "Did your skill weave lead finish did it do a full weave did you consume it what happened here on your watch.";
    const polishedText =
      "Did your skill weave lead finish? Did it do a full weave? Did you consume it? What happened here on your watch?";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [
            {
              message: {
                content: requests.length === 1 ? cleanedText : polishedText,
              },
            },
          ],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(requests).toHaveLength(2);
      expect(result).toMatchObject({
        text: polishedText,
        status: "applied",
        changed: true,
        retried: true,
      });
    } finally {
      server.stop(true);
    }
  });

  it("does not retry a short already-good no-op polish response", async () => {
    const requests: Record<string, unknown>[] = [];
    const cleanedText = "Can I close you?";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [{ message: { content: cleanedText } }],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(requests).toHaveLength(1);
      expect(result).toMatchObject({
        text: cleanedText,
        status: "applied",
        changed: false,
        retried: false,
      });
    } finally {
      server.stop(true);
    }
  });

  it("does not retry a long multi-sentence no-op polish response", async () => {
    const requests: Record<string, unknown>[] = [];
    const cleanedText =
      "Fixed the bug. Ran the tests. Opened the PR. Wrote the report. Notified the lead.";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [{ message: { content: cleanedText } }],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(requests).toHaveLength(1);
      expect(result).toMatchObject({
        text: cleanedText,
        status: "applied",
        changed: false,
        retried: false,
      });
    } finally {
      server.stop(true);
    }
  });

  it("retries twice and adds a deterministic punctuation floor when HTTP polish keeps no-oping", async () => {
    const requests: Record<string, unknown>[] = [];
    const cleanedText =
      "did your skill weave lead finish did it do a full weave did you consume it what happened here on your watch because i need the answer now";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        requests.push((await request.json()) as Record<string, unknown>);
        return Response.json({
          choices: [{ message: { content: cleanedText } }],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(requests).toHaveLength(3);
      expect(result).toMatchObject({
        text: "Did your skill weave lead finish? Did it do a full weave? Did you consume it? What happened here on your watch because i need the answer now?",
        status: "applied",
        changed: true,
        retried: true,
      });
    } finally {
      server.stop(true);
    }
  });

  it("marks a failed HTTP no-op retry fallback as failed", async () => {
    let completionRequests = 0;
    const cleanedText =
      "did your skill weave lead finish did it do a full weave did you consume it what happened here on your watch because i need the answer now";
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        completionRequests += 1;
        if (completionRequests === 1) {
          return Response.json({
            choices: [{ message: { content: cleanedText } }],
          });
        }
        return new Response("retry unavailable", { status: 503 });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: cleanedText,
        cleanedText,
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(completionRequests).toBe(2);
      expect(result).toMatchObject({
        text: "Did your skill weave lead finish? Did it do a full weave? Did you consume it? What happened here on your watch because i need the answer now?",
        status: "failed",
        changed: true,
        retried: true,
        polished: false,
      });
      expect(result.error).toContain("503");
    } finally {
      server.stop(true);
    }
  });

  it("accepts the mlx_lm.server response shape where message is a string", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: (request) => {
        const url = new URL(request.url);
        if (url.pathname === "/v1/models") {
          return Response.json({ data: [] });
        }
        return Response.json({
          choices: [
            {
              message: "Also, do /whats-new and output that as your summary.",
            },
          ],
        });
      },
    });

    try {
      const result = await polishTranscriptionText({
        rawText: "also, do / what's new and output that as your summary",
        cleanedText: "Also, do / what's new and output that as your summary",
        env: {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
          QA_VOICE_STT_POLISH_LOG_PATH: TEST_LOG,
        },
      });

      expect(result.text).toBe(
        "Also, do /whats-new and output that as your summary.",
      );
    } finally {
      server.stop(true);
    }
  });
});
