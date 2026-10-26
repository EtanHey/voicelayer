import { describe, expect, it } from "bun:test";
import { getToolDefinitions } from "../mcp-tools";

describe("spoken tool description style contract", () => {
  for (const name of ["voice_ask", "voice_speak"]) {
    it(`${name} includes a compact spoken-question guide`, () => {
      const tool = getToolDefinitions().find((tool) => tool.name === name);
      expect(tool).toBeDefined();
      const description = tool!.description;
      for (const rule of [
        "Announce who is speaking",
        "who is asking",
        "front-load the ask",
        "sentences of about 15 words or fewer",
        "one question per ask",
        '"One. … Two. …"',
        "single word",
        "No markdown, URLs, code or long identifiers aloud",
        "End with the question itself",
      ]) {
        expect(description).toContain(rule);
      }
      const guide = description.split("Spoken style: ")[1]?.split("\n")[0];
      expect(guide).toBeDefined();
      expect(guide!.length).toBeLessThanOrEqual(400);
      expect(description.length).toBeLessThanOrEqual(name === "voice_ask" ? 3100 : 1800);
    });
  }
});
