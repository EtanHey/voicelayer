import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const pagePath = join(import.meta.dir, "page.tsx");

describe("notch V10 unified mock page", () => {
  test("renders only the selected hybrid on a full-screen audit surface", () => {
    expect(existsSync(pagePath)).toBe(true);

    const source = readFileSync(pagePath, "utf8");
    expect(source).toContain("HybridNotchPrototype");
    expect(source).toContain("Unified liquid glass");
    expect(source).not.toContain("NeutralNotchPrototype");
    expect(source).not.toContain("AdaptiveNotchPrototype");
    expect(source).not.toContain("Material endpoints");
    expect(source).toContain("purple-audit");
  });
});
