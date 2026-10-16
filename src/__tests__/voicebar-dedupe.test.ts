import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// Real subprocesses: standalone p95 <= 2787 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 12_000;

test("dedupe preserves the exact TTS label but backs up a duplicate VoiceBar agent", () => {
  const dir = mkdtempSync(join(tmpdir(), "vb-dedupe-"));
  try {
    const bin = join(dir, "bin"), agents = join(dir, "Library/LaunchAgents");
    mkdirSync(bin); mkdirSync(agents, { recursive: true });
    const app = join(dir, "VoiceBar.app"); mkdirSync(app);
    const stub = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, {mode: 0o700});
    stub("codesign", "echo 'Authority=Developer ID Application: Fixture' >&2; echo 'TeamIdentifier=PPN23G925Y' >&2");
    for (const name of ["mdfind", "find", "pgrep", "osascript"]) stub(name, "exit 0");
    // plistlib keeps the LaunchAgent fixture test runnable on Linux CI too.
    writeFileSync(join(bin, "PlistBuddy"), `#!/usr/bin/python3
import plistlib, sys
with open(sys.argv[-1], "rb") as file:
    data = plistlib.load(file)
value = data
for key in sys.argv[2].split()[1].split(":")[1:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(value)
`, {mode: 0o700});
    stub("launchctl", `printf '%s\\n' "$*" >> '${dir}/launchctl.log'`);
    const plist = (file: string, label: string, target: string) => writeFileSync(join(agents, file),
      `<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>${target}</string></array></dict></plist>`);
    // Filename deliberately differs from Label; the daemon lives inside VoiceBar.
    plist("renamed-tts.plist", "com.golems.tts-daemon", `${app}/Contents/MacOS/VoiceBar`);
    plist("com.golems.tts-daemon-copy.plist", "com.golems.tts-daemon-copy", "/old/VoiceBar.app/Contents/MacOS/VoiceBar");
    plist("resource-user.plist", "com.example.helper", `${app}/Contents/Resources/helper.py`);
    plist("duplicate.plist", "com.voicelayer.old", "/old/VoiceBar.app/Contents/MacOS/VoiceBar");
    for (const [file, extra] of [["program-only.plist", ""], ["program-wins.plist", "<key>ProgramArguments</key><array><string>/other/resource.py</string></array>"]]) {
      writeFileSync(join(agents, file), `<plist version="1.0"><dict><key>Label</key><string>com.example.${file}</string><key>Program</key><string>/old/VoiceBar.app/Contents/MacOS/VoiceBar</string>${extra}</dict></plist>`);
    }
    mkdirSync(join(dir, "lib"));
    writeFileSync(join(dir, "lib/voicebar-launchagent.sh"), readFileSync(new URL("../../scripts/lib/voicebar-launchagent.sh", import.meta.url), "utf8"));
    const script = join(dir, "dedupe.sh");
    writeFileSync(script, readFileSync(new URL("../../scripts/voicelayer-dedupe-voicebar.sh", import.meta.url), "utf8")
      .replaceAll("/usr/libexec/PlistBuddy", join(bin, "PlistBuddy"))
      .replaceAll("/Applications/VoiceBar.app", app)
      .replaceAll("/Library/LaunchAgents /Library/LaunchDaemons", `${dir}/system-agents ${dir}/system-daemons`));
    const result = Bun.spawnSync(["/bin/bash", script, "--apply", "--no-stop", "--no-relaunch"], {
      env: {...process.env, HOME: dir, PLIST_BUDDY: join(bin, "PlistBuddy"), PATH: `${bin}:/usr/bin:/bin`},
    });
    expect(result.exitCode).toBe(0);
    expect(existsSync(join(agents, "renamed-tts.plist"))).toBe(true);
    expect(existsSync(join(agents, "resource-user.plist"))).toBe(true);
    const backup = join(dir, ".voicelayer/voicebar-dedupe-backup");
    const saved = join(backup, readdirSync(backup)[0], "LaunchAgents");
    expect(readdirSync(saved).sort()).toEqual(["com.golems.tts-daemon-copy.plist", "duplicate.plist", "program-only.plist", "program-wins.plist"]);
    expect(existsSync(join(agents, "duplicate.plist"))).toBe(false);
    expect(existsSync(join(agents, "com.golems.tts-daemon-copy.plist"))).toBe(false);
    expect(readFileSync(join(dir, "launchctl.log"), "utf8")).not.toContain("/renamed-tts");
    expect(result.stdout.toString()).toContain("prune:");
  } finally { rmSync(dir, { recursive: true, force: true }); }
}, SUBPROCESS_TEST_TIMEOUT_MS);
