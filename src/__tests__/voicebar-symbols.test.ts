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

  test("the npm package includes the complete symbol catalog", () => {
    const pack = Bun.spawnSync(["npm", "pack", "--dry-run", "--json", "--ignore-scripts"], {
      cwd: repo, env: process.env, stderr: "pipe",
    });
    expect(pack.exitCode, pack.stderr.toString()).toBe(0);
    const files = JSON.parse(pack.stdout.toString())[0].files
      .map(({ path }: { path: string }) => path)
      .filter((path: string) => path.startsWith("flow-bar/Symbols/"));
    expect(files).toContain("flow-bar/Symbols/VoiceBarSymbols.xcassets/Contents.json");
    expect(files).toContain("flow-bar/Symbols/VoiceBarSymbols.xcassets/voicebar.history.take.symbolset/Contents.json");
    expect(files).toContain("flow-bar/Symbols/VoiceBarSymbols.xcassets/voicebar.history.take.symbolset/voicebar.history.take.svg");
  });

  const settings = readFileSync(join(repo, "flow-bar/Sources/VoiceBarUI/SettingsView.swift"), "utf8");

  test("General renders the visible steps from the repair presentation model", () => {
    const setup = settings.slice(settings.indexOf("private var setupSection:"), settings.indexOf("private func setupStepRow"));
    expect(setup).toMatch(/let visibleSteps = setupRepairFeedback\.visibleSteps\(/);
    expect(setup).toContain("ForEach(visibleSteps");
  });

  test("History transcript Copy uses the shared copy confirmation and preserves availability", () => {
    const actions = settings.slice(settings.indexOf("private func historyActionButton("));
    const copy = actions.slice(actions.indexOf("case .copy:"), actions.indexOf("case .paste:"));
    const checks = ["CopyFeedbackButton", ".disabled(disabled)", '.help(reason ?? "Copy transcript")',
      '.accessibilityHint(reason ?? "")', "return onCopyHistoryTranscript(text)"];
    expect(checks.filter(check => !copy.includes(check))).toEqual([]);
  });

  test("build-app.sh stages the catalog before the gate and installs it before signing", () => {
    const step = buildScript.slice(buildScript.indexOf("SYMBOL_CATALOG="));
    expect(step).toContain('xcrun actool "$SYMBOL_CATALOG" --compile "$symbol_stage"');
    expect(step).toContain("--minimum-deployment-target 14.0");
    expect(step).toContain('[ ! -s "$symbol_stage/Assets.car" ]');
    expect(step.slice(0, step.indexOf("fi\n"))).toContain("exit 1");
    expect(buildScript.indexOf("SYMBOL_CATALOG=")).toBeLessThan(buildScript.indexOf('vl_update_gate "$REPO_ROOT" bash'));
    const copy = buildScript.indexOf('cp "$symbol_stage/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"');
    expect(copy).toBeGreaterThan(buildScript.indexOf('mkdir -p "$APP_DIR/Contents/Resources"'));
    expect(copy).toBeLessThan(buildScript.indexOf('echo "[build-app] Signing..."'));
    expect(existsSync(join(repo, "flow-bar/Symbols/VoiceBarSymbols.xcassets/Contents.json"))).toBe(true);
  });
});
