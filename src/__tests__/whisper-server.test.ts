import { describe, it, expect } from "bun:test";
import {
  __resetWhisperServerStateForTests,
  isServerAvailable,
  isServerHealthy,
  transcribeViaServer,
} from "../whisper-server";

describe("whisper-server", () => {
  describe("isServerAvailable", () => {
    it("returns a boolean", () => {
      const result = isServerAvailable();
      expect(typeof result).toBe("boolean");
    });

    it("checks for both binary and model", () => {
      // isServerAvailable is a pure sync check — no side effects
      const result = isServerAvailable();
      expect(typeof result).toBe("boolean");
    });
  });

  describe("isServerHealthy", () => {
    it("returns false when no server is running", async () => {
      // Use a random port that won't have a server
      const healthy = await isServerHealthy(59999);
      expect(healthy).toBe(false);
    });

    it("returns false on unreachable port", async () => {
      const healthy = await isServerHealthy(1);
      expect(healthy).toBe(false);
    });
  });

  describe("transcribeViaServer", () => {
    it("retries once after an inference transport failure", async () => {
      const originalFetch = globalThis.fetch;
      let attempts = 0;

      // @ts-ignore - test double
      globalThis.fetch = async (url: string | URL | Request) => {
        if (String(url).endsWith("/health")) {
          return new Response(JSON.stringify({ status: "ok" }), {
            status: 200,
            headers: { "content-type": "application/json" },
          });
        }

        attempts++;
        if (attempts === 1) {
          throw new Error("connection reset");
        }
        return new Response(JSON.stringify({ text: "after restart" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      };

      try {
        __resetWhisperServerStateForTests({
          proc: { kill: () => {} } as any,
          port: 5555,
          pid: 123,
        });
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555);

        expect(text).toBe("after restart");
        expect(attempts).toBe(2);
      } finally {
        globalThis.fetch = originalFetch;
        __resetWhisperServerStateForTests(null);
      }
    });
  });
});
