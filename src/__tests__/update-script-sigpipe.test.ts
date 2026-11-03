import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const scripts = join(import.meta.dir, "../../scripts");
const dedupe = readFileSync(join(scripts, "voicelayer-dedupe-voicebar.sh"), "utf8");

// Execute the actual helpers and shell options, without running inventory or apply.
function signatureReaders() {
  const options = dedupe.match(/^set -euo pipefail$/m)?.[0];
  const helpers = dedupe.split("# --- codesign helpers")[1]?.split("# --- 1.")[0];
  if (!options || !helpers) throw new Error("dedupe shell options/helpers not found");
  return `${options}\n${helpers.slice(helpers.indexOf("app_authority()"))}`;
}

// This is a targeted shell lint, not a shell parser. Join continuations so a
// producer on the preceding line is classified with its consumer.
function unsafePipelines(source: string): string[] {
  const body = source.replace(/^\s*#.*$/gm, "").replace(/\\\n\s*/g, " ");
  const hits: string[] = [];
  const consumers = /\|[ \t]*(head\b[^\n|]*|grep\b[^\n|]*|awk\b[^'\n]*'[^']*')/g;
  for (const match of body.matchAll(consumers)) {
    const consumer = match[1];
    if (!consumer) continue;
    const earlyExit = /^head\b/.test(consumer)
      || /^grep\b[^\n]*\s-[A-Za-z]*[qm]/.test(consumer)
      || (/^awk\b/.test(consumer)
        && /\bexit\b/.test(consumer.replace(/END\s*\{[^{}]*\}/g, "")));
    if (!earlyExit) continue;
    const prefix = body.slice(0, match.index);
    const producer = prefix.split(/[\n;|]/).at(-1)?.trim() ?? "";
    // printf is an explicitly allowed bounded producer in this lint. Prefer
    // here-strings for unbounded captured output even when printf is a builtin.
    if (/(?:^|\$\()\s*printf\s/.test(producer)) continue;
    hits.push(`${producer} | ${consumer}`);
  }
  return hits;
}

describe("update script SIGPIPE guards", () => {
  for (const reader of ["app_authority", "app_teamid"]) {
    test(`${reader} drains a codesign producer larger than the pipe buffer`, () => {
      const root = mkdtempSync(join(tmpdir(), "g4-sigpipe-"));
      try {
        writeFileSync(join(root, "payload"), "padding=" + "x".repeat(1024 * 1024) + "\n");
        writeFileSync(join(root, "codesign"), `#!/bin/bash
printf 'Authority=Developer ID Application: Fixture\nTeamIdentifier=PPN23G925Y\nAuthority=Later Certificate\nTeamIdentifier=LATER\n'
exec /bin/cat "$G4_PAYLOAD"
`, { mode: 0o700 });
        const result = Bun.spawnSync(["/bin/bash", "-c", `${signatureReaders()}
value="$(${reader} /fixture/VoiceBar.app)"
printf '%s\\n' "$value"
`], {
          env: { ...process.env, PATH: `${root}:/usr/bin:/bin`, G4_PAYLOAD: join(root, "payload") },
        });
        console.info(`${reader}: rc=${result.exitCode}`);
        expect(result.exitCode).toBe(0);
        expect(result.stdout.toString().trim()).toBe(reader === "app_authority"
          ? "Developer ID Application: Fixture" : "PPN23G925Y");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }

  test("unsigned copies return empty signature fields without aborting", () => {
    const root = mkdtempSync(join(tmpdir(), "g4-unsigned-"));
    try {
      writeFileSync(join(root, "codesign"), "#!/bin/bash\nprintf 'not signed at all\\n' >&2\nexit 1\n", { mode: 0o700 });
      const result = Bun.spawnSync(["/bin/bash", "-c", `${signatureReaders()}
authority="$(app_authority /fixture/VoiceBar.app)"
team="$(app_teamid /fixture/VoiceBar.app)"
printf '<%s><%s>\\n' "$authority" "$team"
`], { env: { ...process.env, PATH: `${root}:/usr/bin:/bin` } });
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString()).toBe("<><>\n");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  for (const manager of ["bun", "npm"]) {
    test(`${manager} package-version reader drains output and keeps the first match`, () => {
      const root = mkdtempSync(join(tmpdir(), "g4-package-"));
      try {
        const source = readFileSync(join(scripts, "voicelayer-update.sh"), "utf8");
        const reader = source.slice(source.indexOf("installed_package_version() {"),
          source.indexOf("\nupdate_voicebar_app()"));
        expect(reader).toContain("installed_package_version()");
        writeFileSync(join(root, "payload"), "padding=" + "x".repeat(1024 * 1024) + "\n");
        writeFileSync(join(root, manager), `#!/bin/bash
printf 'voicelayer-mcp@2.2.61\nvoicelayer-mcp@older\n'
/bin/cat "$G4_PAYLOAD" || exit "$?"
printf complete > "$G4_DRAINED"
`, { mode: 0o700 });
        const result = Bun.spawnSync(["/bin/bash", "-c", `set -euo pipefail
unset VOICELAYER_UPDATE_TEST_PACKAGE_VERSION
PACKAGE_NAME=voicelayer-mcp
${reader}
value="$(installed_package_version)"
printf '%s\\n' "$value"
`], { env: { ...process.env, PATH: `${root}:/usr/bin:/bin`, G4_PAYLOAD: join(root, "payload"), G4_DRAINED: join(root, "drained") } });
        expect(result.exitCode).toBe(0);
        expect(result.stdout.toString()).toBe("2.2.61\n");
        expect(result.stderr.toString()).toBe("");
        expect(readFileSync(join(root, "drained"), "utf8")).toBe("complete");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }

  for (const [reader, row, expected] of [
    ["secure_input_owner", '"kCGSSessionSecureInputPID" = 59247', "59247"],
    ["launchd_loaded_program", " program = /fixture/VoiceBar.app/Contents/MacOS/VoiceBar", "/fixture/VoiceBar.app/Contents/MacOS/VoiceBar"],
  ]) {
    test(`${reader} consumes large matching health output`, () => {
      const root = mkdtempSync(join(tmpdir(), "g4-health-"));
      try {
        writeFileSync(join(root, "payload"), `${row}\n`.repeat(20_000));
        const result = Bun.spawnSync(["/bin/bash", "-c", `
VOICEBAR_HOTKEY_HEALTH_SOURCE_ONLY=1 source "$1"
input="$(cat "$2")"
${reader} "$input"
`, "_", join(scripts, "verify-voicebar-hotkey-health.sh"), join(root, "payload")], {
          env: process.env,
        });
        expect(result.exitCode).toBe(0);
        expect(result.stdout.toString().trim()).toBe(expected);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }

  test("lint rejects early consumers of streaming producers", () => {
    for (const source of [
      "codesign -dvvv app 2>&1 | awk -F= '/^Authority=/{print $2; exit}'",
      "bun pm ls -g | awk -v name=foo '\n /foo/ { print; exit }\n'",
      "launchctl print job \\\n | head -n 1",
      "ioreg | grep -q pattern",
      "ioreg | grep -Fq pattern",
      "ioreg | grep -m 1 pattern",
      "printf '%s' value | sed -n /pattern/p | head -n 1",
    ]) expect(unsafePipelines(source)).toHaveLength(1);
    for (const source of [
      "printf '%s' value | awk '/foo/ { print; exit }'",
      "ioreg | awk '/foo/ { found=1 } END { exit(found ? 0 : 1) }'",
      "ioreg | awk 'NR == 1 { print }'",
      "grep -q pattern regular-file",
    ]) expect(unsafePipelines(source)).toEqual([]);
  });

  test("update-path scripts have no early consumers of streaming producers", () => {
    const files = [
      "voicelayer-update.sh", "voicelayer-dedupe-voicebar.sh",
      "verify-voicebar-hotkey-health.sh", "install-voicebar-autostart.sh",
      "install-voicebar-f5-hidutil.sh",
      ...readdirSync(join(scripts, "lib")).filter(name => name.endsWith(".sh")).map(name => `lib/${name}`),
    ];
    const violations = files.flatMap(file => unsafePipelines(readFileSync(join(scripts, file), "utf8"))
      .map(hit => `${file}: ${hit}`));
    expect(violations).toEqual([]);
  });
});
