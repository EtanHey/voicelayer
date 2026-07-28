import { describe, expect, it } from "bun:test";
import { resolvePushToEnd } from "../push-to-end";

describe("push-to-end policy", () => {
  it("journals every honored request with its caller", () => {
    const events: Array<{
      type: string;
      payload: Record<string, unknown>;
      options: { topic?: string };
    }> = [];

    const pushToEnd = resolvePushToEnd(true, {
      caller: "mcp.voice_ask",
      env: { VOICELAYER_ALLOW_PUSH_TO_END: "1" },
      warn: () => {
        throw new Error("gate-open requests must not warn");
      },
      appendEvent(type, payload, options) {
        events.push({ type, payload, options });
      },
    });

    expect(pushToEnd).toBe(true);
    expect(events).toEqual([
      {
        type: "capture.push_to_end_honored",
        payload: {
          caller: "mcp.voice_ask",
          push_to_end: true,
        },
        options: { topic: "voice.input" },
      },
    ]);
  });
});
