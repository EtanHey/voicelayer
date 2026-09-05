import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const installScript = join(
  import.meta.dir,
  "..",
  "..",
  "scripts",
  "install-voicebar-autostart.sh",
);

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
  /** Exit status the stub `xattr` returns (1 == attribute absent). */
  xattrStatus?: number;
  /** Omit the `xattr` stub entirely, simulating a machine without xattr. */
  withXattr?: boolean;
};

type Workspace = {
  home: string;
  appBundle: string;
  stubDir: string;
  log: string;
};

function makeWorkspace(options: StubOptions): Workspace {
  const root = mkdtempSync(join(tmpdir(), "voicebar-autostart-"));
  workspaces.push(root);

  const home = join(root, "home");
  const stubDir = join(root, "bin");
  const appBundle = join(root, "Applications", "VoiceBar.app");
  const log = join(root, "calls.log");
  mkdirSync(home, { recursive: true });
  mkdirSync(stubDir, { recursive: true });
  mkdirSync(appBundle, { recursive: true });
  writeFileSync(log, "");

  const launchctl = join(stubDir, "launchctl");
  writeFileSync(
    launchctl,
    `#!/usr/bin/env bash
printf 'launchctl %s\\n' "$*" >> "$STUB_LOG"
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
  chmodSync(launchctl, 0o755);

  // plutil is macOS-only; stub it so the suite also runs on the Linux CI box.
  const plutil = join(stubDir, "plutil");
  writeFileSync(
    plutil,
    `#!/usr/bin/env bash
printf 'plutil %s\\n' "$*" >> "$STUB_LOG"
exit 0
`,
  );
  chmodSync(plutil, 0o755);

  if (options.withXattr !== false) {
    const xattr = join(stubDir, "xattr");
    writeFileSync(
      xattr,
      `#!/usr/bin/env bash
printf 'xattr %s\\n' "$*" >> "$STUB_LOG"
exit ${options.xattrStatus ?? 0}
`,
    );
    chmodSync(xattr, 0o755);
  }

  return { home, appBundle, stubDir, log };
}

function runInstaller(workspace: Workspace, args: string[] = []) {
  const root = join(workspace.stubDir, "..");
  return spawnSync("bash", [installScript, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: workspace.home,
      PATH: `${workspace.stubDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
      STUB_LOG: workspace.log,
      STUB_STATE: join(root, "print-count"),
      VOICEBAR_APP_PATH: workspace.appBundle,
    },
  });
}

async function readLog(workspace: Workspace): Promise<string[]> {
  const text = await Bun.file(workspace.log).text();
  return text.split("\n").filter((line) => line.trim().length > 0);
}

function expectQuarantineStrippedBeforeBootstrap(lines: string[]) {
  const bootstrapIndexes = lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => line.startsWith("launchctl bootstrap"))
    .map(({ index }) => index);
  expect(bootstrapIndexes.length).toBeGreaterThan(0);

  const stripIndexes = lines
    .map((line, index) => ({ line, index }))
    .filter(({ line }) => line.includes("xattr -d -r com.apple.quarantine"))
    .map(({ index }) => index);
  expect(stripIndexes.length).toBeGreaterThan(0);

  for (const bootstrapIndex of bootstrapIndexes) {
    expect(stripIndexes.some((index) => index < bootstrapIndex)).toBe(true);
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

  test("still succeeds when xattr is absent from PATH", async () => {
    const workspace = makeWorkspace({ printLoaded: 0, withXattr: false });

    const result = runInstaller(workspace);

    expect(result.stderr).not.toContain("xattr");
    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expect(lines.some((line) => line.startsWith("launchctl bootstrap"))).toBe(
      true,
    );
  });

  test("still succeeds when the quarantine attribute is absent", async () => {
    const workspace = makeWorkspace({ printLoaded: 0, xattrStatus: 1 });

    const result = runInstaller(workspace);

    expect(result.status).toBe(0);
    const lines = await readLog(workspace);
    expectQuarantineStrippedBeforeBootstrap(lines);
  });
});
