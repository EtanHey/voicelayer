import { describe, expect, it, mock } from "bun:test";
import {
  askSpokenlyDictation,
  collectVoiceInput,
  collectVoiceInputWithSource,
  getConfiguredVoiceInputBackend,
  getSpokenlyMcpUrl,
} from "../voice-input-backend";

describe("voice input backend selection", () => {
  it("defaults to local input to preserve existing voice_ask behavior", () => {
    expect(getConfiguredVoiceInputBackend({})).toBe("local");
  });

  it("accepts VOICELAYER_INPUT_BACKEND before legacy QA_VOICE_INPUT_BACKEND", () => {
    expect(
      getConfiguredVoiceInputBackend({
        VOICELAYER_INPUT_BACKEND: "spokenly",
        QA_VOICE_INPUT_BACKEND: "local",
      }),
    ).toBe("spokenly");
  });

  it("falls back to the default Spokenly MCP URL", () => {
    expect(getSpokenlyMcpUrl({})).toBe("http://localhost:51089");
  });
});

describe("askSpokenlyDictation", () => {
  it("calls Spokenly's ask_user_dictation MCP tool with questions:string[]", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl = mock(async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), init: init ?? {} });
      return new Response(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: {
            content: [{ type: "text", text: "Use Spokenly for the capture." }],
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });

    const transcript = await askSpokenlyDictation({
      question: "What should we do?",
      timeoutMs: 30_000,
      url: "http://localhost:51089",
      fetchImpl,
    });

    expect(transcript).toBe("Use Spokenly for the capture.");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(calls[0].url).toBe("http://localhost:51089");
    expect(calls[0].init.method).toBe("POST");
    expect(JSON.parse(String(calls[0].init.body))).toMatchObject({
      jsonrpc: "2.0",
      method: "tools/call",
      params: {
        name: "ask_user_dictation",
        arguments: { questions: ["What should we do?"] },
      },
    });
  });

  it("surfaces Spokenly MCP tool errors", async () => {
    const fetchImpl = mock(async () => {
      return new Response(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: {
            isError: true,
            content: [{ type: "text", text: "Spokenly is not ready" }],
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });

    await expect(
      askSpokenlyDictation({
        question: "Anything?",
        timeoutMs: 30_000,
        fetchImpl,
      }),
    ).rejects.toThrow("Spokenly is not ready");
  });
});

describe("collectVoiceInput", () => {
  it("uses the local waitForInput backend by default", async () => {
    const localWaitForInput = mock(async () => "local transcript");
    const fetchImpl = mock(async () => {
      throw new Error("should not call Spokenly");
    });

    const transcript = await collectVoiceInput({
      question: "Question",
      timeoutMs: 30_000,
      silenceMode: "thoughtful",
      pressToTalk: false,
      env: {},
      localWaitForInput,
      fetchImpl,
    });

    expect(transcript).toBe("local transcript");
    expect(localWaitForInput).toHaveBeenCalledWith(
      30_000,
      "thoughtful",
      false,
    );
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("uses Spokenly when configured", async () => {
    const localWaitForInput = mock(async () => "local transcript");
    const fetchImpl = mock(async () => {
      return new Response(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: {
            content: [{ type: "text", text: "spokenly transcript" }],
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });

    const transcript = await collectVoiceInput({
      question: "Question",
      timeoutMs: 30_000,
      silenceMode: "thoughtful",
      pressToTalk: false,
      env: { VOICELAYER_INPUT_BACKEND: "spokenly" },
      localWaitForInput,
      fetchImpl,
    });

    expect(transcript).toBe("spokenly transcript");
    expect(localWaitForInput).not.toHaveBeenCalled();
  });

  it("falls back to local input in auto mode when Spokenly is unavailable", async () => {
    const localWaitForInput = mock(async () => "fallback transcript");
    const fetchImpl = mock(async () => {
      throw new Error("Connection refused");
    });

    const transcript = await collectVoiceInput({
      question: "Question",
      timeoutMs: 30_000,
      silenceMode: "thoughtful",
      pressToTalk: false,
      env: { VOICELAYER_INPUT_BACKEND: "auto" },
      localWaitForInput,
      fetchImpl,
    });

    expect(transcript).toBe("fallback transcript");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(localWaitForInput).toHaveBeenCalledTimes(1);
  });
});

describe("collectVoiceInputWithSource", () => {
  it("reports Spokenly as the source when delegated capture succeeds", async () => {
    const localWaitForInput = mock(async () => "local transcript");
    const fetchImpl = mock(async () => {
      return new Response(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: {
            content: [{ type: "text", text: "spokenly transcript" }],
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });

    const result = await collectVoiceInputWithSource({
      question: "Question",
      timeoutMs: 30_000,
      silenceMode: "thoughtful",
      pressToTalk: false,
      env: { VOICELAYER_INPUT_BACKEND: "auto" },
      localWaitForInput,
      fetchImpl,
    });

    expect(result).toEqual({
      source: "spokenly",
      transcript: "spokenly transcript",
    });
  });

  it("reports local as the source when auto mode falls back", async () => {
    const localWaitForInput = mock(async () => "fallback transcript");
    const fetchImpl = mock(async () => {
      throw new Error("Connection refused");
    });

    const result = await collectVoiceInputWithSource({
      question: "Question",
      timeoutMs: 30_000,
      silenceMode: "thoughtful",
      pressToTalk: false,
      env: { VOICELAYER_INPUT_BACKEND: "auto" },
      localWaitForInput,
      fetchImpl,
    });

    expect(result).toEqual({
      source: "local",
      transcript: "fallback transcript",
    });
  });
});
