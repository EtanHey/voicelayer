import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  getSTTPolishMode,
  polishTranscriptionText,
} from "../stt-polish";

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

  it("rejects low-similarity self-correction rewrites even with explicit cues", async () => {
    server = createMockPolishServer(() => ({
      text: "Please run tests before merge.",
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
      polishedText: "Please run tests before merge.",
      status: "rejected",
      changed: false,
    });
    expect(result.error).toContain("self-correction rewrite changed too much");
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
      expect(messages[0].content).toContain("Input: First of all");
      expect(messages[0].content).toContain(".at");
      expect(messages[0].content).toContain("Preserve Hebrew");
      expect(messages[0].content).toContain("If unsure, return the input unchanged");
      expect(messages[1].content).toContain(
        "Also, do / what's new and output that as your summary",
      );
    } finally {
      server.stop(true);
    }
  });

  it("accepts the mlx_lm.server response shape where message is a string", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: () =>
        Response.json({
          choices: [
            {
              message: "Also, do /whats-new and output that as your summary.",
            },
          ],
        }),
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
