import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const plistTemplate = readFileSync(
  join(repoRoot, "launchd", "com.voicelayer.mcp-daemon.plist"),
  "utf-8",
);
const installScript = readFileSync(
  join(repoRoot, "launchd", "install.sh"),
  "utf-8",
);
const buildScript = readFileSync(
  join(repoRoot, "flow-bar", "build-app.sh"),
  "utf-8",
);

describe("MCP daemon LaunchAgent install contract", () => {
  test("runs the daemon from the installed VoiceBar bundle by default", () => {
    expect(installScript).toContain("/Applications/VoiceBar.app");
    expect(installScript).toContain('BUNDLE_RESOURCES_DIR="$APP_DIR/Contents/Resources"');
    expect(installScript).toContain(
      '$BUNDLE_RESOURCES_DIR/src/mcp-server-daemon.ts',
    );
  });

  test("plist bakes in daemon runtime PATH needed by launchd", () => {
    expect(plistTemplate).toContain("__HOME__/.bun/bin");
    expect(plistTemplate).toContain(
      "/Library/Frameworks/Python.framework/Versions/3.13/bin",
    );
    expect(plistTemplate).toContain("/opt/homebrew/bin");
  });

  test("daemon logs go to a stable user log directory", () => {
    expect(plistTemplate).toContain("__LOG_DIR__");
    expect(plistTemplate).not.toContain("/tmp/voicelayer-mcp-daemon.stderr.log");
    expect(plistTemplate).not.toContain("/tmp/voicelayer-mcp-daemon.stdout.log");
  });

  test("daemon is kept alive unless explicitly disabled", () => {
    expect(plistTemplate).toContain("<key>KeepAlive</key>");
    expect(plistTemplate).toContain("<key>PathState</key>");
    expect(plistTemplate).toContain("/tmp/.voicelayer-daemon-disabled");
    expect(plistTemplate).not.toContain("<key>SuccessfulExit</key>");
  });

  test("VoiceBar rebuild installs the LaunchAgent only when the app is not running", () => {
    expect(buildScript).toContain("launchd/install.sh");
    expect(buildScript).toContain("VOICEBAR_SKIP_LAUNCHD_INSTALL");
    expect(buildScript).toContain("VOICEBAR_FORCE_LAUNCHD_INSTALL");
    expect(buildScript).toContain("pgrep -x VoiceBar");
    expect(buildScript).toContain(
      "Skipping MCP daemon LaunchAgent install while VoiceBar is running",
    );
  });

  test("VoiceBar build script stores at most one app backup outside /Applications", () => {
    expect(buildScript).not.toContain("/Applications/VoiceBar.backup-");
    expect(buildScript).not.toMatch(/\/Applications\/[^"\n]*VoiceBar\.backup-.*\.app/);
    expect(buildScript).toContain('VOICEBAR_BACKUP_DIR="${VOICEBAR_BACKUP_DIR:-$HOME/Library/Application Support/VoiceBar/Backups}"');
    expect(buildScript).toContain('mkdir -p "$VOICEBAR_BACKUP_DIR"');
    expect(buildScript).toContain('find "$VOICEBAR_BACKUP_DIR"');
  });

  test("VoiceBar build script refuses to replace the live app without an explicit force flag", () => {
    expect(buildScript).toContain('VOICEBAR_FORCE_APP_REPLACE');
    expect(buildScript).toContain('Refusing to replace /Applications/VoiceBar.app while VoiceBar is running');
  });
});
