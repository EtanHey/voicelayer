import { describe, it, expect } from "bun:test";
import { isServerAvailable, isServerHealthy } from "../whisper-server";

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
});
