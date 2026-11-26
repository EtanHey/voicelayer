import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "fs";
import { join } from "path";

// T19b (L68): VoiceBar's custom History symbol ships as a compiled asset catalog in the app bundle.
const repo = join(import.meta.dir, "..", "..");
const buildScript = readFileSync(join(repo, "flow-bar", "build-app.sh"), "utf-8");
const symbolset = join(
  repo,
  "flow-bar/Symbols/VoiceBarSymbols.xcassets/voicebar.history.take.symbolset",
);

describe("VoiceBar custom symbols", () => {
  test("the History take-loop template is committed with its catalog entry", () => {
    const contents = JSON.parse(readFileSync(join(symbolset, "Contents.json"), "utf-8"));
    expect(contents.symbols[0].filename).toBe("voicebar.history.take.svg");
    const svg = readFileSync(join(symbolset, "voicebar.history.take.svg"), "utf-8");
    // actool refuses a template without a Regular-M glyph.
    expect(svg).toContain('<g id="Regular-M"');
    expect(svg).toMatch(/<path d="M[-0-9.]+ [-0-9.]+/);
  });

  test("build-app.sh compiles the catalog into Contents/Resources and fails closed", () => {
    const step = buildScript.slice(buildScript.indexOf("SYMBOL_CATALOG="));
    expect(step).toContain('xcrun actool "$SYMBOL_CATALOG" --compile "$APP_DIR/Contents/Resources"');
    expect(step).toContain("--minimum-deployment-target 14.0");
    expect(step).toContain('[ ! -f "$APP_DIR/Contents/Resources/Assets.car" ]');
    expect(step.slice(0, step.indexOf("fi\n"))).toContain("exit 1");
    // The step runs after the bundle's Resources folder exists and before signing.
    expect(buildScript.indexOf("SYMBOL_CATALOG=")).toBeGreaterThan(
      buildScript.indexOf('mkdir -p "$APP_DIR/Contents/Resources"'),
    );
    expect(existsSync(join(repo, "flow-bar/Symbols/VoiceBarSymbols.xcassets/Contents.json"))).toBe(true);
  });
});
