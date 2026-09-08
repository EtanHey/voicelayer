import { afterEach, beforeEach, describe, expect, it } from "bun:test";

const originalEnv = { ...process.env };

function restoreEnv() {
  for (const key of Object.keys(process.env)) {
    if (!(key in originalEnv)) delete process.env[key];
  }
  Object.assign(process.env, originalEnv);
}

describe("android appliance bridge config", () => {
  afterEach(() => {
    restoreEnv();
  });

  it("is disabled by default and uses the browser prototype URL default", async () => {
    delete process.env.QA_VOICE_ANDROID_APPLIANCE;
    delete process.env.QA_VOICE_ANDROID_APPLIANCE_URL;

    const { resolveAndroidApplianceConfig } = await import("../android-bridge");

    expect(resolveAndroidApplianceConfig()).toEqual({
      enabled: false,
      baseUrl: "http://127.0.0.1:8765",
      timeoutMs: 5000,
    });
  });

  it("is enabled only by the explicit feature flag", async () => {
    process.env.QA_VOICE_ANDROID_APPLIANCE = "1";
    process.env.QA_VOICE_ANDROID_APPLIANCE_URL = "http://127.0.0.1:18765/";
    process.env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS = "1200";

    const { resolveAndroidApplianceConfig } = await import("../android-bridge");

    expect(resolveAndroidApplianceConfig()).toEqual({
      enabled: true,
      baseUrl: "http://127.0.0.1:18765",
      timeoutMs: 1200,
    });
  });
});

describe("AndroidApplianceBridge", () => {
  let requests: { method: string; path: string; body?: unknown }[];
  let server: ReturnType<typeof Bun.serve>;
  let baseUrl: string;

  beforeEach(() => {
    requests = [];
  });

  afterEach(() => {
    server?.stop(true);
    restoreEnv();
  });

  function serve(handler: (req: Request) => Response | Promise<Response>) {
    server = Bun.serve({
      port: 0,
      fetch: handler,
    });
    baseUrl = `http://127.0.0.1:${server.port}`;
  }

  it("reports unavailable when health is unhealthy", async () => {
    serve(() => Response.json({ ok: false, state: "idle" }));

    const { AndroidApplianceBridge } = await import("../android-bridge");
    const bridge = new AndroidApplianceBridge({ baseUrl, timeoutMs: 1000 });

    const result = await bridge.checkHealth();

    expect(result).toEqual({
      ok: false,
      reason: "unhealthy",
    });
  });

  it("starts a protocol recording after a healthy idle response", async () => {
    serve(async (req) => {
      const url = new URL(req.url);
      requests.push({
        method: req.method,
        path: url.pathname,
        body: req.method === "POST" ? await req.json() : undefined,
      });
      if (url.pathname === "/health") {
        return Response.json({ ok: true, api_version: 1, state: "idle" });
      }
      if (url.pathname === "/start") {
        return Response.json({
          ok: true,
          session_id: "android-session",
          state: "recording",
        });
      }
      return new Response("not found", { status: 404 });
    });

    const { AndroidApplianceBridge } = await import("../android-bridge");
    const bridge = new AndroidApplianceBridge({
      baseUrl,
      timeoutMs: 1000,
      sessionIdFactory: () => "android-session",
    });

    const result = await bridge.startRecording({
      timeoutMs: 30_000,
      pressToTalk: true,
    });

    expect(result).toEqual({
      ok: true,
      sessionId: "android-session",
      source: "android",
    });
    expect(requests).toEqual([
      { method: "GET", path: "/health", body: undefined },
      {
        method: "POST",
        path: "/start",
        body: {
          session_id: "android-session",
          mode: "ptt",
          sample_rate: 16000,
          channels: 1,
          encoding: "pcm_s16le",
          timeout_seconds: 30,
        },
      },
    ]);
  });

  it("treats busy start responses as unavailable for local fallback", async () => {
    serve((req) => {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return Response.json({ ok: true, api_version: 1, state: "idle" });
      }
      if (url.pathname === "/start") {
        return Response.json({ ok: false, error: "busy" }, { status: 409 });
      }
      return new Response("not found", { status: 404 });
    });

    const { AndroidApplianceBridge } = await import("../android-bridge");
    const bridge = new AndroidApplianceBridge({
      baseUrl,
      timeoutMs: 1000,
      sessionIdFactory: () => "busy-session",
    });

    const result = await bridge.startRecording({
      timeoutMs: 30_000,
      pressToTalk: false,
    });

    expect(result).toEqual({
      ok: false,
      reason: "busy",
    });
  });

  it("stops a recording and pulls WAV bytes for Mac-side transcription", async () => {
    const wavBytes = new Uint8Array([82, 73, 70, 70, 1, 2, 3, 4]);
    serve((req) => {
      const url = new URL(req.url);
      requests.push({ method: req.method, path: `${url.pathname}${url.search}` });
      if (url.pathname === "/stop") {
        return Response.json({
          ok: true,
          session_id: "android-session",
          state: "ready",
          duration_ms: 1200,
        });
      }
      if (url.pathname === "/pull_audio") {
        return new Response(wavBytes, {
          headers: { "content-type": "audio/wav" },
        });
      }
      return new Response("not found", { status: 404 });
    });

    const { AndroidApplianceBridge } = await import("../android-bridge");
    const bridge = new AndroidApplianceBridge({ baseUrl, timeoutMs: 1000 });

    const stop = await bridge.stopRecording("android-session");
    const audio = await bridge.pullAudio("android-session");

    expect(stop).toEqual({ ok: true, durationMs: 1200 });
    expect([...audio!]).toEqual([...wavBytes]);
    expect(requests).toEqual([
      { method: "POST", path: "/stop" },
      { method: "GET", path: "/pull_audio?session_id=android-session" },
    ]);
  });

  it("cancels an active appliance recording without pulling audio", async () => {
    serve(async (req) => {
      requests.push({
        method: req.method,
        path: new URL(req.url).pathname,
        body: await req.json(),
      });
      return Response.json({
        ok: true,
        session_id: "android-session",
        state: "idle",
      });
    });

    const { AndroidApplianceBridge } = await import("../android-bridge");
    const bridge = new AndroidApplianceBridge({ baseUrl, timeoutMs: 1000 });

    const result = await bridge.cancelRecording("android-session");

    expect(result).toEqual({ ok: true });
    expect(requests).toEqual([
      {
        method: "POST",
        path: "/cancel",
        body: { session_id: "android-session" },
      },
    ]);
  });
});
