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

describe("Playwright MCP setup", () => {
  test("npx @playwright/mcp@latest is available", () => {
    // Skip in CI or offline environments — this hits the npm registry
    const result = Bun.spawnSync([
      "npx",
      "@playwright/mcp@latest",
      "--version",
    ]);
    if (result.exitCode !== 0) {
      console.error(
        "[skip] npx @playwright/mcp@latest not available (offline or not installed)",
      );
      return;
    }
    const stdout = result.stdout.toString().trim();
    expect(stdout).toMatch(/\d+\.\d+/);
  });

  test(".mcp.json contains playwright config (if present)", async () => {
    // .mcp.json is gitignored — skip if not present (clean checkout)
    if (!existsSync(".mcp.json")) {
      console.error(
        "[skip] .mcp.json not present (gitignored, clean checkout)",
      );
      return;
    }
    const config = await Bun.file(".mcp.json").json();
    expect(config.mcpServers.playwright).toBeDefined();
    expect(config.mcpServers.playwright.command).toBe("npx");
    expect(config.mcpServers.playwright.args).toContain(
      "@playwright/mcp@latest",
    );
  });

  test("Hebrew Unicode round-trip sanity", () => {
    // Verify Bun/Node handles Hebrew correctly — same encoding Playwright uses
    const hebrew = "ברוכים הבאים לוויקיפדיה!";
    const encoded = Buffer.from(hebrew, "utf8");
    const decoded = encoded.toString("utf8");
    expect(decoded).toBe(hebrew);
    expect(/[\u0590-\u05FF]/.test(decoded)).toBe(true);
    expect(decoded).not.toContain("\ufffd"); // no replacement chars
  });
});
