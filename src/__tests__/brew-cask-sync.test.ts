import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const syncLib = join(repoRoot, "scripts", "lib", "brew-cask-sync.sh");
const token = "etanhey/layers/voicebar";

type Sandbox = {
  root: string;
  prefix: string;
  caskroom: string;
  tapRepo: string;
  appPath: string;
  brewLog: string;
  brewStub: string;
  backupRoot: string;
};

function infoPlist(version: string) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    "<dict>",
    "\t<key>CFBundleShortVersionString</key>",
    `\t<string>${version}</string>`,
    "</dict>",
    "</plist>",
    "",
  ].join("\n");
}

// A self-contained fake Homebrew. The stub is FAITHFUL, not pinned: installing
// really creates the Caskroom entry and really rewrites the app's Info.plist, so
// the drift detection under test reads the same surfaces it reads on a real Mac.
function sandbox(options: {
  appVersion?: string;
  registeredVersion?: string;
  offeredVersion?: string;
  savedUninstall?: string;
}): Sandbox {
  const offeredVersion = options.offeredVersion ?? "2.2.6";
  const root = mkdtempSync(join(tmpdir(), "brew-cask-sync-"));
  const prefix = join(root, "prefix");
  const brewRepository = join(root, "brew-repo");
  const tapRepo = join(brewRepository, "Library/Taps/etanhey/homebrew-layers");
  const caskroom = join(prefix, "Caskroom", "voicebar");
  const appPath = join(root, "Applications", "VoiceBar.app");
  const brewLog = join(root, "brew.log");
  const brewStub = join(root, "bin", "brew");
  const backupRoot = join(root, "backups");

  mkdirSync(join(tapRepo, "Casks"), { recursive: true });
  mkdirSync(join(root, "bin"), { recursive: true });
  mkdirSync(join(prefix, "Caskroom"), { recursive: true });

  writeFileSync(
    join(tapRepo, "Casks", "voicebar.rb"),
    `cask "voicebar" do\n  version "${offeredVersion}"\nend\n`,
  );

  if (options.appVersion) {
    mkdirSync(join(appPath, "Contents"), { recursive: true });
    writeFileSync(
      join(appPath, "Contents", "Info.plist"),
      infoPlist(options.appVersion),
    );
  }

  if (options.registeredVersion) {
    mkdirSync(join(caskroom, options.registeredVersion), { recursive: true });
    const savedCaskDir = join(
      caskroom,
      ".metadata",
      options.registeredVersion,
      "20260101000000.000",
      "Casks",
    );
    mkdirSync(savedCaskDir, { recursive: true });
    writeFileSync(
      join(savedCaskDir, "voicebar.rb"),
      options.savedUninstall ??
        'cask "voicebar" do\n  uninstall trash: ["~/Library/LaunchAgents/x.plist"]\nend\n',
    );
  }

  writeFileSync(
    brewStub,
    [
      "#!/usr/bin/env bash",
      'printf "%s\\n" "$*" >> "$BREW_STUB_LOG"',
      'offered="$(awk \'/version "/ { gsub(/"/, "", $2); print $2; exit }\' "$BREW_STUB_TAP_CASK")"',
      "install_offered() {",
      '  rm -rf "$BREW_STUB_PREFIX"/Caskroom/voicebar/[0-9]*',
      '  mkdir -p "$BREW_STUB_PREFIX/Caskroom/voicebar/$offered"',
      '  mkdir -p "$BREW_STUB_APP/Contents"',
      '  printf "%s" "$BREW_STUB_PLIST_TEMPLATE" | sed "s/__VERSION__/$offered/" > "$BREW_STUB_APP/Contents/Info.plist"',
      "}",
      'case "$1 $2" in',
      '  "--prefix ") printf "%s\\n" "$BREW_STUB_PREFIX" ;;',
      '  "--repository ") printf "%s\\n" "$BREW_STUB_REPOSITORY" ;;',
      '  "list --versions")',
      '    for dir in "$BREW_STUB_PREFIX"/Caskroom/voicebar/*/; do',
      '      [[ -d "$dir" ]] || continue',
      '      name="$(basename "$dir")"',
      '      printf "voicebar %s\\n" "$name"',
      "      exit 0",
      "    done",
      "    exit 1",
      "    ;;",
      '  "install --cask"|"upgrade --cask") install_offered ;;',
      "esac",
      "exit 0",
      "",
    ].join("\n"),
  );
  chmodSync(brewStub, 0o755);

  return { root, prefix, caskroom, tapRepo, appPath, brewLog, brewStub, backupRoot };
}

function runInLib(box: Sandbox, body: string, env: Record<string, string> = {}) {
  return Bun.spawnSync(["bash", "-c", `. "${syncLib}"\n${body}`], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      BREW_CASK_SYNC_BREW_BIN: box.brewStub,
      BREW_STUB_LOG: box.brewLog,
      BREW_STUB_PREFIX: box.prefix,
      BREW_STUB_REPOSITORY: join(box.root, "brew-repo"),
      BREW_STUB_APP: box.appPath,
      BREW_STUB_TAP_CASK: join(box.tapRepo, "Casks", "voicebar.rb"),
      BREW_STUB_PLIST_TEMPLATE: infoPlist("__VERSION__"),
      ...env,
    },
  });
}

function sync(box: Sandbox) {
  return runInLib(
    box,
    `bcs_sync_cask ${token} "${box.appPath}" "${box.backupRoot}"`,
  );
}

function decode(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

function brewCalls(box: Sandbox) {
  return existsSync(box.brewLog) ? readFileSync(box.brewLog, "utf8") : "";
}

function installedAppVersion(box: Sandbox) {
  const plist = join(box.appPath, "Contents", "Info.plist");
  if (!existsSync(plist)) return "";
  return readFileSync(plist, "utf8").match(/<string>(.*)<\/string>/)?.[1] ?? "";
}

function registeredVersions(box: Sandbox) {
  if (!existsSync(box.caskroom)) return [];
  return readdirSync(box.caskroom).filter((entry) => !entry.startsWith("."));
}

describe("brew-cask-sync drift detection", () => {
  const cases: Array<[string, string | undefined, string | undefined, string]> = [
    ["both agree", "2.2.6", "2.2.6", "managed"],
    ["ledger behind the disk (the 2026-08-19 shape)", "2.2.5", "2.1.10", "version-drift"],
    ["hand-placed bundle", "2.2.5", undefined, "unmanaged"],
    ["registered but no app", undefined, "2.1.10", "registered-without-app"],
    ["nothing installed", undefined, undefined, "absent"],
  ];

  for (const [label, appVersion, registeredVersion, expected] of cases) {
    test(`${label} -> ${expected}`, () => {
      const box = sandbox({ appVersion, registeredVersion });
      const result = runInLib(box, `bcs_drift_state ${token} "${box.appPath}"`);

      expect(result.exitCode).toBe(0);
      expect(decode(result.stdout).trim()).toBe(expected);
    });
  }
});

describe("brew-cask-sync repair", () => {
  test("version drift adopts with --force and never runs an upgrade", () => {
    const box = sandbox({
      appVersion: "2.2.5",
      registeredVersion: "2.1.10",
      offeredVersion: "2.2.6",
    });
    const result = sync(box);
    const calls = brewCalls(box);

    expect(decode(result.stdout)).toContain("drift detected (version-drift)");
    expect(calls).toContain(`install --cask --force ${token}`);
    expect(calls).not.toContain("upgrade --cask");
    expect(calls).not.toContain("uninstall");
    expect(installedAppVersion(box)).toBe("2.2.6");
    expect(registeredVersions(box)).toEqual(["2.2.6"]);
    expect(result.exitCode).toBe(0);
  });

  test("the stale registration is moved aside, never deleted", () => {
    const box = sandbox({ appVersion: "2.2.5", registeredVersion: "2.1.10" });
    sync(box);

    const kept = readdirSync(box.backupRoot);
    expect(kept.length).toBe(1);
    expect(kept[0]).toContain("voicebar-caskroom-");
    expect(existsSync(join(box.backupRoot, kept[0]!, "2.1.10"))).toBe(true);
  });

  test("a hand-placed unmanaged app is adopted in place", () => {
    const box = sandbox({ appVersion: "2.2.6", offeredVersion: "2.2.6" });
    const result = sync(box);

    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toContain("drift detected (unmanaged)");
    expect(brewCalls(box)).toContain(`install --cask --force ${token}`);
    expect(registeredVersions(box)).toEqual(["2.2.6"]);
  });

  test("a machine with nothing installed gets a plain install", () => {
    const box = sandbox({ offeredVersion: "2.2.6" });
    const result = sync(box);

    expect(result.exitCode).toBe(0);
    expect(brewCalls(box)).toContain(`install --cask ${token}`);
    expect(brewCalls(box)).not.toContain("--force");
    expect(installedAppVersion(box)).toBe("2.2.6");
  });

  test("a root-only saved uninstall recipe is routed around, not run", () => {
    // Ledger and disk agree at 2.1.10 and only the tap is ahead, so the naive
    // path is `brew upgrade --cask` -- which is exactly what broke the Mac.
    const box = sandbox({
      appVersion: "2.1.10",
      registeredVersion: "2.1.10",
      offeredVersion: "2.2.6",
      savedUninstall: [
        'cask "voicebar" do',
        "  uninstall delete: [",
        '    "~/Library/LaunchAgents/com.voicelayer.voicebar.plist",',
        "  ]",
        "end",
        "",
      ].join("\n"),
    });
    const result = sync(box);
    const calls = brewCalls(box);

    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toContain("root-only recipe");
    expect(calls).toContain(`install --cask --force ${token}`);
    expect(calls).not.toContain("upgrade --cask");
    expect(installedAppVersion(box)).toBe("2.2.6");
  });

  test("a sudo-free saved recipe still takes the ordinary upgrade path", () => {
    const box = sandbox({
      appVersion: "2.2.5",
      registeredVersion: "2.2.5",
      offeredVersion: "2.2.6",
    });
    const result = sync(box);

    expect(result.exitCode).toBe(0);
    expect(brewCalls(box)).toContain(`upgrade --cask ${token}`);
    expect(brewCalls(box)).not.toContain("--force");
    expect(installedAppVersion(box)).toBe("2.2.6");
  });

  test("running against an already-canonical Mac is a no-op", () => {
    const box = sandbox({
      appVersion: "2.2.6",
      registeredVersion: "2.2.6",
      offeredVersion: "2.2.6",
    });
    const result = sync(box);
    const calls = brewCalls(box);

    expect(result.exitCode).toBe(0);
    expect(calls).not.toContain("install --cask");
    expect(calls).not.toContain("upgrade --cask");
    expect(existsSync(box.backupRoot)).toBe(false);
    expect(decode(result.stdout)).toContain("already canonical at 2.2.6");
  });

  test("a second run straight after a repair changes nothing", () => {
    const box = sandbox({
      appVersion: "2.2.5",
      registeredVersion: "2.1.10",
      offeredVersion: "2.2.6",
    });
    expect(sync(box).exitCode).toBe(0);
    rmSync(box.brewLog);

    const second = sync(box);
    expect(second.exitCode).toBe(0);
    expect(brewCalls(box)).not.toContain("install --cask");
    expect(brewCalls(box)).not.toContain("upgrade --cask");
    expect(decode(second.stdout)).toContain("already canonical at 2.2.6");
    expect(readdirSync(box.backupRoot).length).toBe(1);
  });

  test("an unwritable Caskroom stops before anything is destroyed", () => {
    const box = sandbox({ appVersion: "2.2.5", registeredVersion: "2.1.10" });
    chmodSync(join(box.prefix, "Caskroom"), 0o555);
    try {
      const result = sync(box);

      expect(result.exitCode).not.toBe(0);
      expect(decode(result.stderr)).toContain("would need sudo");
      expect(decode(result.stderr)).toContain("Nothing has been changed");
      expect(existsSync(join(box.caskroom, "2.1.10"))).toBe(true);
      expect(brewCalls(box)).not.toContain("install --cask");
    } finally {
      chmodSync(join(box.prefix, "Caskroom"), 0o755);
    }
  });

  test("a repair that does not reach the offered version fails loudly", () => {
    const box = sandbox({
      appVersion: "2.2.5",
      registeredVersion: "2.1.10",
      offeredVersion: "2.2.6",
    });
    // A brew that reports success but installs nothing.
    writeFileSync(box.brewStub, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(box.brewStub, 0o755);

    const result = runInLib(
      box,
      `bcs_sync_cask ${token} "${box.appPath}" "${box.backupRoot}"`,
      { BREW_CASK_SYNC_TEST_OFFERED_VERSION: "2.2.6" },
    );

    expect(result.exitCode).not.toBe(0);
    expect(decode(result.stderr)).toContain("did not reach the offered version 2.2.6");
  });
});

describe("brew-cask-sync environment contract", () => {
  test("the tap is refreshed with an explicit remote and branch", () => {
    const box = sandbox({});
    Bun.spawnSync(["git", "init", "-q", box.tapRepo], { stderr: "ignore" });
    const result = runInLib(box, "bcs_tap_update etanhey/layers main");

    // There is no `origin` in the sandbox; the shape of the call is the point.
    expect(decode(result.stdout)).toContain("pull --ff-only origin main");
  });

  test("an untapped tap is tapped rather than pulled", () => {
    const box = sandbox({});
    rmSync(box.tapRepo, { recursive: true, force: true });
    const result = runInLib(box, "bcs_tap_update etanhey/layers main");

    expect(result.exitCode).toBe(0);
    expect(brewCalls(box)).toContain("tap etanhey/layers");
  });

  test("the library works when sourced from zsh, not just bash", () => {
    // The M1's non-interactive ssh shell is zsh, where `declare -F <name>`
    // succeeds for an UNDEFINED function -- the bash idiom silently calls a
    // missing run_cmd. Caught on the real M1 on 2026-08-19.
    const box = sandbox({ appVersion: "2.2.6", registeredVersion: "2.2.6" });
    const result = Bun.spawnSync(
      [
        "zsh",
        "-c",
        `. "${syncLib}"\nbcs_sync_cask ${token} "${box.appPath}" "${box.backupRoot}"`,
      ],
      {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
        env: {
          ...process.env,
          BREW_CASK_SYNC_BREW_BIN: box.brewStub,
          BREW_STUB_LOG: box.brewLog,
          BREW_STUB_PREFIX: box.prefix,
          BREW_STUB_REPOSITORY: join(box.root, "brew-repo"),
          BREW_STUB_APP: box.appPath,
          BREW_STUB_TAP_CASK: join(box.tapRepo, "Casks", "voicebar.rb"),
          BREW_STUB_PLIST_TEMPLATE: infoPlist("__VERSION__"),
        },
      },
    );

    expect(decode(result.stderr)).not.toContain("command not found");
    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toContain("already canonical at 2.2.6");
  });

  test("function detection does not use the zsh-broken declare -F idiom", () => {
    const executable = readFileSync(syncLib, "utf8")
      .split("\n")
      .filter((line) => !line.trim().startsWith("#"))
      .join("\n");

    expect(executable).not.toContain("declare -F");
    expect(executable).toContain("typeset -f");
  });

  test("brew is resolved by absolute path, not PATH", () => {
    const body = readFileSync(syncLib, "utf8");

    expect(body).toContain("/opt/homebrew/bin/brew");
    expect(body).toContain("/usr/local/bin/brew");
  });

  test("the library never invokes sudo", () => {
    const body = readFileSync(syncLib, "utf8");
    const executable = body
      .split("\n")
      .filter((line) => !line.trim().startsWith("#"))
      .join("\n");

    expect(executable).not.toContain("/usr/bin/sudo");
    expect(executable).not.toMatch(/(^|[;&|(]\s*)sudo\s/m);
  });

  test("the library uses the shell hardening baseline", () => {
    const body = readFileSync(syncLib, "utf8");

    expect(body).toContain("#!/usr/bin/env bash");
    expect(body).not.toContain("eval ");
  });
});
