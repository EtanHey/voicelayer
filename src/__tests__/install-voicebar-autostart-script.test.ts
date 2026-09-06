import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

const installScript = join(
  import.meta.dir,
  "..",
  "..",
  "scripts",
  "install-voicebar-autostart.sh",
);

// The stub directory is the ENTIRE PATH the script runs under, so `xattr` is
// genuinely absent when we say it is -- inheriting /usr/bin would hand the
// script the real macOS `xattr` and quietly invalidate the absence case. That
// means every external command the script (and our stubs) reach for has to be
// linked in explicitly. `bash` is on the list because the stubs' `/usr/bin/env
// bash` shebang resolves the interpreter through PATH.
const REAL_TOOLS = [
  "bash",
  "cat",
  "chmod",
  "cmp",
  "cp",
  "dirname",
  "id",
  "mkdir",
  "sleep",
];

const workspaces: string[] = [];

afterEach(() => {
  while (workspaces.length > 0) {
    const dir = workspaces.pop();
    if (dir) {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

type StubOptions = {
  /** How many `launchctl print` calls report the job as loaded. */
  printLoaded: number;
  /** Exit status of the stub's `xattr -d` (non-zero == removal failed). */
  xattrDeleteStatus?: number;
  /** Exit status of the stub's `xattr -p` (0 == attribute still present). */
  xattrProbeStatus?: number;
  /** Omit the `xattr` stub entirely, simulating a machine without xattr. */
  withXattr?: boolean;
  /** Omit the app bundle, simulating a machine with no VoiceBar installed. */
  withAppBundle?: boolean;
};

type Workspace = {
  home: string;
  appBundle: string;
  stubDir: string;
  log: string;
  /** Stands in for /tmp, so the cleanup is exercised without touching the real one. */
  legacyLogDir: string;
};

function writeStub(path: string, body: string) {
  writeFileSync(path, `#!/usr/bin/env bash\n${body}`);
  chmodSync(path, 0o755);
}

function makeWorkspace(options: StubOptions): Workspace {
  const root = mkdtempSync(join(tmpdir(), "voicebar-autostart-"));
  workspaces.push(root);

  const home = join(root, "home");
  const stubDir = join(root, "bin");
  const appBundle = join(root, "Applications", "VoiceBar.app");
  const log = join(root, "calls.log");
  mkdirSync(home, { recursive: true });
  mkdirSync(stubDir, { recursive: true });
  if (options.withAppBundle !== false) {
    mkdirSync(appBundle, { recursive: true });
  }
  writeFileSync(log, "");

  for (const tool of REAL_TOOLS) {
    const resolved = Bun.which(tool);
    if (!resolved) {
      throw new Error(`test harness needs ${tool} on PATH`);
    }
    symlinkSync(resolved, join(stubDir, tool));
  }

  writeStub(
    join(stubDir, "launchctl"),
    `printf 'launchctl %s\\n' "$*" >> "$STUB_LOG"
if [ "\${1:-}" = "print" ]; then
  count=0
  if [ -f "$STUB_STATE" ]; then count="$(cat "$STUB_STATE")"; fi
  count=$((count + 1))
  printf '%s' "$count" > "$STUB_STATE"
  if [ "$count" -le "${options.printLoaded}" ]; then exit 0; fi
  exit 1
fi
exit 0
`,
  );

  // plutil is macOS-only; stub it so the suite also runs on the Linux CI box.
  writeStub(
    join(stubDir, "plutil"),
    `printf 'plutil %s\\n' "$*" >> "$STUB_LOG"
exit 0
`,
  );

  if (options.withXattr !== false) {
    writeStub(
      join(stubDir, "xattr"),
      `printf 'xattr %s\\n' "$*" >> "$STUB_LOG"
if [ "\${1:-}" = "-p" ]; then exit ${options.xattrProbeStatus ?? 1}; fi
exit ${options.xattrDeleteStatus ?? 0}
`,
    );
  }

  const legacyLogDir = join(root, "legacy-tmp");
  mkdirSync(legacyLogDir, { recursive: true });

  return { home, appBundle, stubDir, log, legacyLogDir };
}

function runInstaller(workspace: Workspace, args: string[] = []) {
  const root = join(workspace.stubDir, "..");
  return spawnSync(join(workspace.stubDir, "bash"), [installScript, ...args], {
    encoding: "utf8",
    env: {
      HOME: workspace.home,
      PATH: workspace.stubDir,
      STUB_LOG: workspace.log,
      STUB_STATE: join(root, "print-count"),
      VOICEBAR_APP_PATH: workspace.appBundle,
      VOICEBAR_LEGACY_LOG_DIR: workspace.legacyLogDir,
    },
  });
}

async function readLog(workspace: Workspace): Promise<string[]> {
  const text = await Bun.file(workspace.log).text();
  return text.split("\n").filter((line) => line.trim().length > 0);
}

function indexesOf(lines: string[], predicate: (line: string) => boolean) {
  return lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => predicate(line))
    .map(({ index }) => index);
}

function stripIndexes(lines: string[]) {
  return indexesOf(lines, (line) =>
    line.includes("xattr -d -r com.apple.quarantine"),
  );
}

function bootstrapIndexes(lines: string[]) {
  return indexesOf(lines, (line) => line.startsWith("launchctl bootstrap"));
}

function expectQuarantineStrippedBeforeBootstrap(lines: string[]) {
  const bootstraps = bootstrapIndexes(lines);
  const strips = stripIndexes(lines);
  expect(bootstraps.length).toBeGreaterThan(0);
  expect(strips.length).toBeGreaterThan(0);

  for (const bootstrap of bootstraps) {
    expect(strips.some((strip) => strip < bootstrap)).toBe(true);
  }
}

describe("install-voicebar-autostart.sh quarantine release", () => {
  test("strips com.apple.quarantine before the fresh-install bootstrap", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expectQuarantineStrippedBeforeBootstrap(lines);
    expect(
      lines.some((line) =>
        line.includes(
          `xattr -d -r com.apple.quarantine ${workspace.appBundle}`,
        ),
      ),
    ).toBe(true);
  });

  test("strips com.apple.quarantine before the --reload bootstrap", async () => {
    const workspace = makeWorkspace({ printLoaded: 1 });

    const result = runInstaller(workspace, ["--reload"]);

    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expectQuarantineStrippedBeforeBootstrap(lines);
  });

  // The cask's postflight is `voicelayer setup` -> `voicelayer autostart install`
  // with NO --reload, so on an upgrade the agent is already loaded and the script
  // never reaches a bootstrap. This is the path that produced the outage.
  test("strips com.apple.quarantine on the already-loaded path that never bootstraps", async () => {
    const workspace = makeWorkspace({ printLoaded: 1 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(result.stdout).toContain("applies on next login");
    const lines = await readLog(workspace);
    expect(bootstrapIndexes(lines)).toHaveLength(0);
    expect(
      lines.some((line) =>
        line.includes(
          `xattr -d -r com.apple.quarantine ${workspace.appBundle}`,
        ),
      ),
    ).toBe(true);
  });

  test("strips com.apple.quarantine even when the agent is left unloaded", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace, ["--no-start"]);

    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expect(stripIndexes(lines).length).toBeGreaterThan(0);
  });

  test("still succeeds when xattr is absent from PATH", async () => {
    const workspace = makeWorkspace({ printLoaded: 0, withXattr: false });

    const result = runInstaller(workspace);

    expect(result.stderr).not.toContain("xattr");
    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expect(stripIndexes(lines)).toHaveLength(0);
    expect(bootstrapIndexes(lines).length).toBeGreaterThan(0);
  });

  test("stays silent and succeeds when the quarantine attribute is absent", async () => {
    const workspace = makeWorkspace({
      printLoaded: 0,
      xattrDeleteStatus: 1,
      xattrProbeStatus: 1,
    });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(result.stderr).not.toContain("WARNING");
    const lines = await readLog(workspace);
    expectQuarantineStrippedBeforeBootstrap(lines);
    expect(
      indexesOf(lines, (line) => line.startsWith("xattr -p")),
    ).toHaveLength(1);
  });

  test("warns loudly, naming the bundle, when the strip fails and quarantine remains", async () => {
    const workspace = makeWorkspace({
      printLoaded: 0,
      xattrDeleteStatus: 1,
      xattrProbeStatus: 0,
    });

    const result = runInstaller(workspace);

    // A warned-about bundle still beats leaving the machine with no LaunchAgent.
    expect(result.status).toBe(0);
    expect(result.stderr).toContain(
      `WARNING: could not strip com.apple.quarantine from ${workspace.appBundle}`,
    );
    const lines = await readLog(workspace);
    expect(bootstrapIndexes(lines).length).toBeGreaterThan(0);
  });

  test("does not call xattr when no bundle is installed yet", async () => {
    const workspace = makeWorkspace({ printLoaded: 0, withAppBundle: false });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expect(indexesOf(lines, (line) => line.startsWith("xattr"))).toHaveLength(
      0,
    );
    expect(bootstrapIndexes(lines).length).toBeGreaterThan(0);
  });
});

// The LaunchAgent's stderr file is VoiceBar's own log. It held a keystroke log of
// everything Etan typed (fixed 2026-09-06), and it sat in /tmp at a predictable
// path with mode 644 — world-readable on a multi-user Mac. launchd does not
// expand $HOME inside a plist string, so the absolute path has to be baked in
// here, at install time.
describe("install-voicebar-autostart.sh log paths", () => {
  function installedPlist(workspace: Workspace): string {
    return readFileSync(
      join(
        workspace.home,
        "Library",
        "LaunchAgents",
        "com.voicelayer.voicebar.plist",
      ),
      "utf8",
    );
  }

  function logDir(workspace: Workspace): string {
    return join(workspace.home, "Library", "Logs", "voicelayer");
  }

  // Read the values, not the file text: the plist carries a comment that
  // mentions /tmp and $HOME on purpose, and asserting against raw text would
  // trip over the explanation of the very bug this guards.
  function logPathValues(workspace: Workspace): string[] {
    const plist = installedPlist(workspace);
    return ["StandardOutPath", "StandardErrorPath"].map((key) => {
      const match = plist.match(
        new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`),
      );
      if (!match) {
        throw new Error(`${key} missing from the installed plist`);
      }
      // The plist stores XML-escaped text; compare against the real path.
      return match[1]
        .replaceAll("&lt;", "<")
        .replaceAll("&gt;", ">")
        .replaceAll("&amp;", "&");
    });
  }

  // The property is "inside the user's own home", not "not literally /tmp":
  // on the Linux CI box tmpdir() IS /tmp, so this workspace's own $HOME sits
  // under /tmp and a literal /tmp check would fail on correct installer output.
  test("keeps the log paths inside the user's home, not a shared directory", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    for (const path of logPathValues(workspace)) {
      expect(path.startsWith(`${workspace.home}/`)).toBe(true);
    }
  });

  test("bakes the absolute per-user log paths into the installed plist", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(logPathValues(workspace)).toEqual([
      join(logDir(workspace), "voicebar.log"),
      join(logDir(workspace), "voicebar-err.log"),
    ]);
    for (const path of logPathValues(workspace)) {
      // launchd takes these literally rather than expanding them.
      expect(path).not.toContain("$HOME");
      expect(path).not.toContain("~");
      expect(path).not.toContain("__VOICEBAR_LOG_DIR__");
    }
  });

  // Splicing a path into XML is new here -- `cp` never interpolated anything --
  // so an unescaped & in $HOME would emit a malformed plist and `plutil -lint`
  // would abort the install.
  test("escapes a home directory that is not XML-safe", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });
    const hostileHome = join(workspace.home, "R&D <team>");
    mkdirSync(hostileHome, { recursive: true });

    const result = spawnSync(
      join(workspace.stubDir, "bash"),
      [installScript],
      {
        encoding: "utf8",
        env: {
          HOME: hostileHome,
          PATH: workspace.stubDir,
          STUB_LOG: workspace.log,
          STUB_STATE: join(workspace.stubDir, "..", "print-count-hostile"),
          VOICEBAR_APP_PATH: workspace.appBundle,
          VOICEBAR_LEGACY_LOG_DIR: workspace.legacyLogDir,
        },
      },
    );

    expect(result.status).toBe(0);
    const plist = readFileSync(
      join(
        hostileHome,
        "Library",
        "LaunchAgents",
        "com.voicelayer.voicebar.plist",
      ),
      "utf8",
    );
    expect(plist).toContain(
      `<string>${hostileHome.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")}/Library/Logs/voicelayer/voicebar-err.log</string>`,
    );
    // bash 5.2 expands a bare `&` in a ${var//pat/rep} replacement to the matched
    // text, which spliced the placeholder back INTO the path on Ubuntu CI while
    // macOS bash 3.2 rendered it correctly. Nothing may survive substitution.
    expect(plist).not.toContain("__VOICEBAR_LOG_DIR__");
    // The log directory is still created at the real, unescaped path.
    expect(
      statSync(join(hostileHome, "Library", "Logs", "voicelayer")).mode & 0o777,
    ).toBe(0o700);
  });

  test("creates the log directory and files private to the user", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(statSync(logDir(workspace)).mode & 0o777).toBe(0o700);
    for (const name of ["voicebar.log", "voicebar-err.log"]) {
      expect(statSync(join(logDir(workspace), name)).mode & 0o777).toBe(0o600);
    }
  });

  test("tightens the mode of log files an earlier install left world-readable", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });
    mkdirSync(logDir(workspace), { recursive: true });
    const leaked = join(logDir(workspace), "voicebar-err.log");
    writeFileSync(leaked, "pre-existing log content\n");
    chmodSync(leaked, 0o644);

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(statSync(leaked).mode & 0o777).toBe(0o600);
    // Repairing the mode must not throw away the operator's existing log.
    expect(readFileSync(leaked, "utf8")).toBe("pre-existing log content\n");
  });

  // The in-place-update branch compares what it is about to write against what
  // is on disk. Rendering the template at install time must not make every run
  // look like a change, or a routine `voicelayer setup` would rewrite the plist
  // forever.
  test("recognises its own rendered plist as already current", async () => {
    const workspace = makeWorkspace({ printLoaded: 99 });

    const first = runInstaller(workspace);
    expect(first.status).toBe(0);
    expect(first.stdout).toContain("applies on next login");

    const repeat = runInstaller(workspace);
    expect(repeat.status).toBe(0);
    expect(repeat.stdout).toContain("already current");
  });
});

// Moving the log path forward does not remediate the machines that already have
// the leak: /tmp/voicebar-err.log survives an upgrade, world-readable, holding a
// keystroke log. The installer empties and tightens it in place.
describe("install-voicebar-autostart.sh legacy /tmp log cleanup", () => {
  test("truncates and tightens a leaked legacy log without deleting it", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });
    const leaked = join(workspace.legacyLogDir, "voicebar-err.log");
    writeFileSync(leaked, "[HotkeyManager] Callback entry keycode=8\n");
    chmodSync(leaked, 0o644);

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    // Still there -- an operator may hold the file open; deleting is not ours to do.
    expect(existsSync(leaked)).toBe(true);
    expect(readFileSync(leaked, "utf8")).toBe("");
    expect(statSync(leaked).mode & 0o777).toBe(0o600);
  });

  test("truncates the legacy stdout log too", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });
    const leaked = join(workspace.legacyLogDir, "voicebar.log");
    writeFileSync(leaked, "noise\n");
    chmodSync(leaked, 0o644);

    expect(runInstaller(workspace).status).toBe(0);

    expect(readFileSync(leaked, "utf8")).toBe("");
    expect(statSync(leaked).mode & 0o777).toBe(0o600);
  });

  // /tmp is world-writable and sticky, so anyone can plant a name there. The
  // cleanup must not follow one into a file it was never meant to touch.
  test("refuses to follow a symlink planted at the legacy path", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });
    const decoy = join(workspace.legacyLogDir, "not-a-log.txt");
    writeFileSync(decoy, "important unrelated content\n");
    symlinkSync(decoy, join(workspace.legacyLogDir, "voicebar-err.log"));

    expect(runInstaller(workspace).status).toBe(0);

    expect(readFileSync(decoy, "utf8")).toBe("important unrelated content\n");
  });

  test("succeeds when there is no legacy log to clean up", async () => {
    const workspace = makeWorkspace({ printLoaded: 0 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    expect(existsSync(join(workspace.legacyLogDir, "voicebar-err.log"))).toBe(
      false,
    );
  });
});
