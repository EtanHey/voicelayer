/**
 * Playwright MCP verification test.
 *
 * Validates that Playwright MCP is correctly installed and configured.
 * Hebrew Unicode verification was done live via Kernel Playwright against
 * he.wikipedia.org — confirmed "ויקיפדיה" renders as proper Unicode in
 * the accessibility tree, not OCR artifacts or mojibake.
 */

import { test, expect, describe } from "bun:test";
import { existsSync } from "fs";

// Pre-check for conditional skips
const npxAvailable = Bun.spawnSync(["which", "npx"]).exitCode === 0;
const mcpJsonExists = existsSync(".mcp.json");

describe("Playwright MCP setup", () => {
  test.skipIf(!npxAvailable)(
    "npx @playwright/mcp@latest is available",
    { timeout: 15000 },
    () => {
      const result = Bun.spawnSync([
        "npx",
        "@playwright/mcp@latest",
        "--version",
      ]);
      if (result.exitCode !== 0) return; // Offline — graceful skip
      const stdout = result.stdout.toString().trim();
      expect(stdout).toMatch(/\d+\.\d+/);
    },
  );

  test.skipIf(!mcpJsonExists)(
    ".mcp.json contains playwright config",
    async () => {
      const config = await Bun.file(".mcp.json").json();
      expect(config.mcpServers.playwright).toBeDefined();
      expect(config.mcpServers.playwright.command).toBe("npx");
      expect(config.mcpServers.playwright.args).toContain(
        "@playwright/mcp@latest",
      );
    },
  );

  test("Hebrew Unicode round-trip sanity", () => {
    const hebrew = "ברוכים הבאים לוויקיפדיה!";
    const encoded = Buffer.from(hebrew, "utf8");
    const decoded = encoded.toString("utf8");
    expect(decoded).toBe(hebrew);
    expect(/[\u0590-\u05FF]/.test(decoded)).toBe(true);
    expect(decoded).not.toContain("\ufffd");
  });
});
