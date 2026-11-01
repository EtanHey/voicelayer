import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, relative } from "path";
import ts from "typescript";

// Exact lines AND occurrence budgets: adding a home path even in an allowed
// file needs review. These exceptions are fixtures, isolation or path contracts.
const ALLOWED: Record<string, Array<[string, number]>> = {
  // Structural STT safety guard: cache entry/target metadata only, no corpus,
  // audio or transcript reads. Exactly one cache-base resolver is authorized.
  "src/__tests__/setup/stt-parakeet-policy.ts": [
    ['const cache = env.XDG_CACHE_HOME || join(homedir(), ".cache");', 1],
  ],
  // Synthetic protocol payloads, no archive access.
  "src/__tests__/ack-protocol.test.ts": [
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\";", 2],
  ],
  // CLI help output assertion; no archive access.
  "src/__tests__/benchmark-audio-input.test.ts": [
    ["expect(result.output).toContain(\"~/.local/share/voicelayer/recordings\");", 1],
  ],
  // Synthetic cask source strings only.
  "src/__tests__/brew-cask-sync.test.ts": [
    ["'cask \"voicebar\" do\\n  uninstall trash: [\"~/Library/LaunchAgents/x.plist\"]\\nend\\n',", 1],
    ["'    \"~/Library/LaunchAgents/com.voicelayer.voicebar.plist\",',", 1],
  ],
  // Synthetic process command strings only.
  "src/__tests__/daemon-startup.test.ts": [
    ["\"/Users/me/.bun/bin/bun run /Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts\",", 1],
    ["readProcessCommand: () => \"bun /Users/me/.bun/bin/voicelayer-mcp\",", 1],
  ],
  // Synthetic state-dir containment fixture.
  "src/__tests__/paths.test.ts": [
    ["const liveStateDir = \"/Users/fixture-user/.local/state/voicelayer\";", 1],
  ],
  // Negative assertion that the isolated journal is outside the real home.
  "src/__tests__/preload-control-layer.test.ts": [
    ["expect(result.base).not.toStartWith(join(homedir(), \".local\", \"share\", \"orc\"));", 1],
  ],
  // Passes HOME to an isolated child; no private path construction.
  "src/__tests__/preload-git-env.test.ts": [
    ["HOME: process.env.HOME ?? \"\",", 1],
  ],
  // Saves, redirects and restores HOME for temporary fixtures.
  "src/__tests__/pronunciation.test.ts": [
    ["const originalHome = process.env.HOME;", 1],
    ["process.env.HOME = caseDir;", 1],
    ["process.env.HOME = originalHome;", 1],
  ],
  // Synthetic profile text, expanded under a temporary HOME.
  "src/__tests__/qwen3-profile-catalog.test.ts": [
    ["const profile = (clip = \"~/.voicelayer/voices/ben-c1/ref.wav\", text = \"Synthetic reference transcript.\") =>", 1],
  ],
  // Profile literals and subprocesses with temporary HOME; existing voices.json preset metadata check only, no corpus.
  "src/__tests__/qwen3.test.ts": [
    ["expect(profile.model_path).toBe(\"~/.voicelayer/models/qwen3-tts-4bit\");", 1],
    ["expect(profile.model).toBe(\"~/.voicelayer/models/qwen3-tts-4bit\");", 2],
    ["\"~/.voicelayer/voices/theo/samples/clip-003.wav\",", 2],
    ["\"~/.voicelayer/voices/theo/samples/clip-011.wav\",", 1],
    ["\"~/.voicelayer/voices/theo/samples/clip-007.wav\",", 1],
    ["expect(profile.reference_clip).toBe(\"~/test.wav\");", 1],
    ["model: \"~/.voicelayer/models/qwen3-tts-4bit\",", 1],
    ["const voicesRoot = join(process.env.HOME, \".voicelayer\", \"voices\");", 1],
    ["const profilePath = join(process.env.HOME, \".voicelayer\", \"voices\", \"theo-c4s\", \"profile.yaml\");", 1],
    ["process.env.HOME || \"~\",", 1],
  ],
  // Pure default-path resolver assertions; no private file reads.
  "src/__tests__/security-hardening.test.ts": [
    ["const home = homedir();", 1],
    ["const expected = join(homedir(), \".local\", \"state\", \"voicelayer\");", 1],
  ],
  // Redirects HOME to TEST_TMP for session fixtures.
  "src/__tests__/session.test.ts": [
    ["process.env.HOME = TEST_HOME;", 1],
  ],
  // Synthetic protocol payloads, no archive access.
  "src/__tests__/socket-protocol.test.ts": [
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\",", 1],
    ["\"/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav\";", 1],
  ],
  // synthetic speakable-symbols probe (home-relative path stays unspoken), not a private path
  "src/__tests__/fixtures/speakable-symbols-main.json": [
    ['{"raw":"~/list/paragraph","edge":"~paragraph","clone":"~slash list slash paragraph"},', 1],
  ],
  // synthetic speakable-symbols probe (home-relative path stays unspoken), not a private path
  "src/__tests__/fixtures/speakable-symbols-probes.json": [
    ['{"raw":"~/list/paragraph","edge":"~paragraph","clone":"~slash list slash paragraph"},', 1],
  ],
  // Synthetic path spoken-text conversion fixture.
  "src/__tests__/speakable-text.test.ts": [
    ["[\"/Users/dev/app/qwen3_tts/qwen3_tts.py\", \"slash Users slash dev slash app slash qwen three T T S slash qwen three T T S dot P Y\"],", 1],
  ],
  // Synthetic path-preservation input; no filesystem access.
  "src/__tests__/stt-polish.test.ts": [
    ["cleanedText: \"Read /Users/fixture-user/project/src/input.ts before editing.\",", 1],
  ],
  // Literal punctuation fixture only.
  "src/__tests__/stt-punctuation.test.ts": [
    ["expect(restoreSentencePunctuation(\"~/Gits/voicelayer\")).toBe(", 1],
    ["\"~/Gits/voicelayer\",", 1],
  ],
  // Synthetic process/launchctl output parsed by the script fixture.
  "src/__tests__/voicebar-hotkey-health-script.test.ts": [
    ["\"\\tpath = /Users/test/Library/LaunchAgents/com.voicelayer.voicebar.plist\",", 1],
    ["\"  456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar\",", 1],
    ["\"456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar\",", 1],
  ],
  // Synthetic rsync arguments under mocked commands.
  "src/__tests__/voicelayer-update-script.test.ts": [
    ["\"fixture-host:/Users/fixture-user\",", 1],
    ["\"fixture-host:/Users/fixture-user/.voicelayer/voices/\",", 1],
  ],
  // Mock HTTP model-path strings only.
  "src/__tests__/whisper-server.test.ts": [
    ["model: \"/Users/me/.cache/whisper/ggml-large-v3-turbo.bin\",", 2],
    ["\"/Users/me/.cache/whisper/ggml-large-v3-turbo.bin\",", 1],
  ],
  // Synthetic profile paths expanded under temporary HOME.
  "tests/test_tts_daemon_security.py": [
    ["\"tilde\": \"~/.voicelayer/voices/fixture-speaker_2/samples/clip 01.wav\",", 1],
    ["\"tilde\": \"~/models/fixture-model\",", 1],
  ],
};

// Keep literal/script-text coverage for every file type. The AST pass also
// sees token boundaries across comments/newlines, optional/bracket access,
// binding aliases and template interpolations. Never execute scanned sources.
function homeLines(source: string): string[] {
  const lines = source.split(/\r?\n/);
  const flagged = new Set<number>();
  lines.forEach((line, index) => {
    if (/\b(?:os\.)?homedir\s*\(|\b(?:process|Bun)\.env(?:\.HOME\b|\[["']HOME["']\])|\$\{\s*HOME\s*\}|["'`]~\/|\/Users\//.test(line)) {
      flagged.add(index);
    }
  });
  const tree = ts.createSourceFile("guard-input.ts", source, ts.ScriptTarget.Latest, true);
  const unwrap = (node: ts.Expression): ts.Expression =>
    ts.isParenthesizedExpression(node) ? unwrap(node.expression) : node;
  function member(node: ts.Node): string | undefined {
    if (ts.isPropertyAccessExpression(node)) return node.name.text;
    if (ts.isElementAccessExpression(node) && ts.isStringLiteralLike(node.argumentExpression)) {
      return node.argumentExpression.text;
    }
    return undefined;
  }
  function environment(node: ts.Expression): boolean {
    node = unwrap(node);
    if (member(node) !== "env" ||
        !(ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node))) return false;
    const root = unwrap(node.expression);
    return ts.isIdentifier(root) && (root.text === "process" || root.text === "Bun");
  }
  function bindingName(node: ts.BindingElement): string | undefined {
    const key = node.propertyName ?? node.name;
    return ts.isIdentifier(key) || ts.isStringLiteralLike(key) ? key.text : undefined;
  }
  function visit(node: ts.Node): void {
    const access = ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node);
    if ((access && (member(node) === "homedir" ||
          (member(node) === "HOME" && environment(node.expression)))) ||
        (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "homedir") ||
        (ts.isImportSpecifier(node) && node.propertyName?.text === "homedir") ||
        (ts.isBindingElement(node) && bindingName(node) === "homedir") ||
        (ts.isVariableDeclaration(node) && ts.isObjectBindingPattern(node.name) &&
          node.initializer && environment(node.initializer) && node.name.elements.some(e => bindingName(e) === "HOME")) ||
        (ts.isTemplateSpan(node) && ts.isIdentifier(node.expression) && node.expression.text === "HOME") ||
        (ts.isStringLiteralLike(node) && node.text.startsWith("~/"))) {
      flagged.add(tree.getLineAndCharacterOfPosition(node.getStart(tree)).line);
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  // One budget unit per original source line, even if multiple detectors fire.
  return [...flagged].sort((a, b) => a - b).map(index => lines[index].trim());
}

function unexpected(file: string, source: string): string[] {
  const budget = new Map(ALLOWED[file] ?? []);
  return homeLines(source).filter(line => {
    const remaining = budget.get(line) ?? 0;
    budget.set(line, remaining - 1);
    return remaining <= 0;
  });
}

function* files(dir: string): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory() && entry.name !== "__pycache__") yield* files(path);
    else if (entry.isFile() && !/\.py[co]$/.test(entry.name)) yield path;
  }
}

function sourceText(path: string): string {
  // Malformed bytes must not hide home paths in otherwise scanned files.
  return readFileSync(path, "utf8");
}

test("private corpus home paths stay in the opt-in helper or reviewed exceptions", () => {
  const root = join(import.meta.dir, "../..");
  const failures: string[] = [];
  for (const dir of ["src/__tests__", "tests"]) {
    for (const path of files(join(root, dir))) {
      const file = relative(root, path);
      // The sole gated private-path resolver; this guard contains its own
      // allowlist literals and adversarial scanner fixtures (never executed).
      if (file === "src/__tests__/setup/private-specimens.ts" ||
          file === "src/__tests__/private-corpus-guard.test.ts") continue;
      const source = sourceText(path);
      for (const line of unexpected(file, source)) {
        failures.push(`${file}: ${line}`);
      }
    }
  }
  expect(failures).toEqual([]);
});

const REJECTED_FORMS = [
  ["bare homedir", "homedir()"],
  ["os homedir", "os.homedir()"],
  ["multiline os homedir", "os\n .\n homedir\n ()"],
  ["multiline require homedir", 'require(\n "os"\n ).\n homedir\n ()'],
  ["node os require homedir", 'require("node:os")["homedir"]()'],
  ["homedir property alias", "const h = os.homedir; h()"],
  ["homedir import alias", 'import { homedir as h } from "os"; h()'],
  ["multiline homedir import alias", 'import {\n homedir\n as h\n } from "node:os"; h()'],
  ["homedir require binding alias", 'const { homedir: h } = require("os"); h()'],
  ["process HOME dot", "process.env.HOME"],
  ["process HOME single bracket", "process.env['HOME']"],
  ["process HOME double bracket", 'process.env["HOME"]'],
  ["multiline process HOME single bracket", "process\n .env[\n 'HOME'\n ]"],
  ["multiline process HOME double bracket", 'process.env[\n "HOME"\n ]'],
  ["Bun HOME dot", "Bun.env.HOME"],
  ["Bun HOME single bracket", "Bun.env['HOME']"],
  ["Bun HOME double bracket", 'Bun.env["HOME"]'],
  ["optional process HOME dot", "process.env?.HOME"],
  ["optional process HOME bracket", 'process.env?.["HOME"]'],
  ["optional Bun HOME dot", "Bun.env?.HOME"],
  ["optional Bun HOME bracket", "Bun.env?.['HOME']"],
  ["bracket env access", 'process["env"]["HOME"]'],
  ["HOME destructuring", "const { HOME } = process.env"],
  ["HOME destructuring alias", "const { HOME: home } = process.env"],
  ["Bun HOME destructuring", "const { HOME } = Bun.env"],
  ["multiline HOME destructuring", "const {\n HOME: home\n } = process\n .env"],
  ["bare HOME template", "`${HOME}/private`"],
  ["Bun HOME template", "`${Bun.env.HOME}/private`"],
  ["process HOME template", "`${process.env.HOME}/private`"],
  ["multiline HOME template", "`${\n process.env[\n 'HOME'\n ]}/private`"],
  ["comment-separated HOME", "process /* fixture */ . env /* fixture */ ?. HOME"],
  ["tilde double literal", '"~/private"'],
  ["tilde single literal", "'~/private'"],
  ["tilde template literal", "`~/private`"],
  ["absolute home literal", '"/Users/private/archive"'],
] as const;

for (const file of ["tests/new.test.ts", "src/__tests__/qwen3.test.ts"]) {
  test.each(REJECTED_FORMS)(`${file} rejects %s`, (_name, source) => {
    expect(unexpected(file, source).length).toBeGreaterThan(0);
  });
}

test("allowlist budgets reject duplicate and modified exceptions", () => {
  for (const file of ["src/__tests__/preload-git-env.test.ts", "src/__tests__/setup/stt-parakeet-policy.ts"]) {
    const line = ALLOWED[file][0][0];
    expect(unexpected(file, line)).toEqual([]);
    expect(unexpected(file, `${line}\n${line}`)).toEqual([line]);
    expect(unexpected(file, `${line} Bun.env.HOME;`)).toHaveLength(1);
  }
});


test("source scanning excludes only Python cache paths, regardless of bytes", () => {
  const root = mkdtempSync(join(tmpdir(), "private-corpus-guard-"));
  const homePath = '"/Users/private/archive"';
  const expected: string[] = [];
  try {
    mkdirSync(join(root, "__pycache__"));
    writeFileSync(join(root, "__pycache__", "cached.py"), homePath);
    for (const name of ["cached.pyc", "cached.pyo"]) {
      writeFileSync(join(root, name), Buffer.concat([Buffer.from([0, 0xff]), Buffer.from(homePath)]));
    }
    for (const extension of [".ts", ".js", ".py", ".sh", ".swift", ".json", ".md", ".unknown", ".bin", ""]) {
      for (const [kind, prefix] of [["text", []], ["nul", [0]], ["invalid-utf8", [0xff]]] as const) {
        const name = `${kind}${extension}`;
        writeFileSync(join(root, name), Buffer.concat([Buffer.from(prefix), Buffer.from(homePath)]));
        expected.push(name);
      }
    }
    const scanned = [...files(root)].map(path => relative(root, path));
    expect(scanned.sort()).toEqual(expected.sort());
    const failures = [...files(root)].flatMap(path =>
      unexpected(relative(root, path), sourceText(path)).map(() => relative(root, path)));
    expect(failures.sort()).toEqual(expected.sort());
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
