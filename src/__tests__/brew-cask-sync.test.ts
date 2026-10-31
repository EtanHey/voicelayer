import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { fixtureGitEnv } from "./setup/git-env";
import { afterAll, afterEach, describe, expect, test } from "bun:test";
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
import { join } from "path";

// Real subprocesses: standalone p95 <= 350 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

const repoRoot = join(import.meta.dir, "..", "..");
const syncLib = join(repoRoot, "scripts", "lib", "brew-cask-sync.sh");
const token = "etanhey/layers/voicebar";
const fixtureRoots: string[] = [];
const pendingFixtureRoots: string[] = [];

afterEach(() => {
  for (const root of pendingFixtureRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

afterAll(() => {
  expect(fixtureRoots.every((root) => !existsSync(root))).toBe(true);
});

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
  const root = mkdtempSync(join(bundleFixtureRoot(), "brew-cask-sync-"));
  fixtureRoots.push(root);
  pendingFixtureRoots.push(root);
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
  // isolation-exempt: fixtureGitEnv retains current isolation keys while removing every inherited Git repository selector
  return Bun.spawnSync(["bash", "-c", `. "${syncLib}"\n${body}`], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...fixtureGitEnv(),
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

describe("active formula reader", () => {
  // Homebrew docs/Querying-Brew.md and Formula#to_hash: linked_keg is a
  // PkgVersion string; installed contains every retained keg, in any order.
  function readFormula(versions: string[], linked: string | null, options: {
    token?: string;
    json?: string;
    queryStatus?: number;
    inventory?: string;
    inventoryStatus?: number;
  } = {}) {
    const box = sandbox({});
    const formula = options.token ?? "etanhey/layers/voicelayer";
    const json = options.json ?? JSON.stringify({ formulae: [{
      name: "voicelayer", full_name: "etanhey/layers/voicelayer",
      installed: versions.map((version) => ({ version })), linked_keg: linked,
    }], casks: [] });
    writeFileSync(join(box.root, "formula.json"), json);
    // Keep a rack candidate for JSON/error controls; model no rack explicitly.
    writeFileSync(join(box.root, "inventory"), options.inventory ?? "voicelayer\n");
    writeFileSync(box.brewStub, [
      "#!/usr/bin/env bash",
      'printf "%s\\n" "$*" >> "$BREW_STUB_LOG"',
      '[[ "$HOMEBREW_NO_AUTO_UPDATE $HOMEBREW_NO_ENV_HINTS" = "1 1" ]] || exit 98',
      'case "$*" in',
      `  "list --formula -1") cat "${join(box.root, "inventory")}"; exit ${options.inventoryStatus ?? 0} ;;`,
      `  "info --json=v2 --formula ${formula}") cat "${join(box.root, "formula.json")}"; exit ${options.queryStatus ?? 0} ;;`,
      `  "list --versions ${formula}") printf '%s\\n' 'voicelayer ${versions.join(" ")}' ;;`,
      '  *) exit 99 ;;',
      "esac", "",
    ].join("\n"));
    const result = runInLib(box, [
      "unset BREW_CASK_SYNC_TEST_FORMULA_VERSION",
      'bcs_formula_version "$FORMULA_TOKEN"',
    ].join("\n"), { FORMULA_TOKEN: formula });
    expect(readFileSync(join(box.root, "formula.json"), "utf8")).toBe(json);
    return { box, result };
  }

  for (const versions of [
    ["2.2.51", "2.2.50", "2.2.54"], // measured MBP order
    ["2.2.50", "2.2.54"], // measured M1 retained/current shape
    ["2.2.54", "2.2.50", "2.2.51"],
    ["2.2.51", "2.2.55", "2.2.54"], // newer inactive keg must not win
  ]) {
    test(`active formula ignores retained order: ${versions.join(", ")}`, () => {
      const { box, result } = readFormula(versions, "2.2.54");
      expect(result.exitCode).toBe(0);
      expect(decode(result.stdout).trim()).toBe("2.2.54");
      expect(brewCalls(box).trim().split("\n")).toEqual([
        "list --formula -1", "info --json=v2 --formula etanhey/layers/voicelayer",
      ]);
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  test("active formula preserves revision and fully qualified identity", () => {
    const { result } = readFormula(["2.2.55", "2.2.54_2"], "2.2.54_2");
    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout).trim()).toBe("2.2.54_2");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("active formula accepts a bare token and reports true absence", () => {
    const { result } = readFormula([], null, { token: "voicelayer" });
    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout).trim()).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  for (const [label, queryStatus, inventory] of [
    ["untapped formula", 1, "jq\nvoicelayer-tools\n"],
    ["available formula", 0, ""],
  ] satisfies Array<[string, number, string]>) {
    test(`active formula inventory proves absence of ${label} before named resolution`, () => {
      const { box, result } = readFormula([], null, {
        queryStatus, inventory, json: queryStatus === 1 ? "" : undefined,
      });
      expect(result.exitCode).toBe(0);
      expect(decode(result.stdout)).toBe("");
      expect(decode(result.stderr)).toBe("");
      expect(brewCalls(box).trim()).toBe("list --formula -1");
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  for (const current of [false, true]) {
    test(`active formula underscore inventory: ${current ? "current" : "absent"} target`, () => {
      const { box, result } = readFormula(current ? ["2.2.55", "2.2.54"] : [], current ? "2.2.54" : null, {
        inventory: current ? "_fixture\nvoicelayer\n" : "_fixture\njq\n",
        ...(current ? {} : { json: "", queryStatus: 1 }),
      });
      expect(result.exitCode).toBe(0);
      expect(decode(result.stdout)).toBe(current ? "2.2.54\n" : "");
      expect(decode(result.stderr)).toBe("");
      expect(brewCalls(box).trim().split("\n")).toEqual(current
        ? ["list --formula -1", "info --json=v2 --formula etanhey/layers/voicelayer"]
        : ["list --formula -1"]);
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  for (const formula of ["_fixture", "etanhey/layers/_fixture"]) {
    test(`active formula underscore token: ${formula}`, () => {
      const { box, result } = readFormula(["2.2.54"], "2.2.54", {
        token: formula, inventory: "_fixture\n",
        json: JSON.stringify({ formulae: [{
          name: "_fixture", full_name: "etanhey/layers/_fixture",
          installed: [{ version: "2.2.54" }], linked_keg: "2.2.54",
        }], casks: [] }),
      });
      expect(result.exitCode).toBe(0);
      expect(decode(result.stdout)).toBe("2.2.54\n");
      expect(decode(result.stderr)).toBe("");
      expect(brewCalls(box).trim().split("\n")).toEqual([
        "list --formula -1", `info --json=v2 --formula ${formula}`,
      ]);
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  for (const formula of [".fixture", "etanhey/layers/.fixture"]) {
    for (const [label, inventory] of [["empty", ""], ["unrelated", "jq\n_fixture\n"]] satisfies Array<[string, string]>) {
      test(`active formula hidden target linked: ${formula} with ${label} inventory`, () => {
        const { box, result } = readFormula(["2.2.55", "2.2.54_2"], "2.2.54_2", {
          token: formula, inventory,
          json: JSON.stringify({ formulae: [{
            name: ".fixture", full_name: "etanhey/layers/.fixture",
            installed: [{ version: "2.2.55" }, { version: "2.2.54_2" }], linked_keg: "2.2.54_2",
          }], casks: [] }),
        });
        expect(result.exitCode).toBe(0);
        expect(decode(result.stdout)).toBe("2.2.54_2\n");
        expect(decode(result.stderr)).toBe("");
        expect(brewCalls(box).trim().split("\n")).toEqual([
          "list --formula -1", `info --json=v2 --formula ${formula}`,
        ]);
      }, SUBPROCESS_TEST_TIMEOUT_MS);
    }
  }

  for (const [label, formula, linked, options] of [
    ["installed-unlinked", ".fixture", null, {}],
    ["missing JSON", "etanhey/layers/.fixture", "2.2.54", { json: "" }],
    ["query failure with valid JSON", "etanhey/layers/.fixture", "2.2.54", { queryStatus: 42 }],
    ["dot-only missing query", ".", null, { json: "", queryStatus: 1 }],
    ["qualified dot-only missing query", "etanhey/layers/..", null, { json: "", queryStatus: 1 }],
  ] satisfies Array<[string, string, string | null, { json?: string; queryStatus?: number }]>) {
    test(`active formula hidden target rejects ${label}`, () => {
      const { box, result } = readFormula(["2.2.54"], linked, {
        token: formula, inventory: "",
        json: JSON.stringify({ formulae: [{
          name: ".fixture", full_name: "etanhey/layers/.fixture",
          installed: [{ version: "2.2.54" }], linked_keg: linked,
        }], casks: [] }), ...options,
      });
      expect(result.exitCode).toBe(1);
      expect(decode(result.stdout)).toBe("");
      expect(decode(result.stderr)).toContain("active formula identity");
      expect(brewCalls(box).trim().split("\n")).toEqual([
        "list --formula -1", `info --json=v2 --formula ${formula}`,
      ]);
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  test("active formula hidden target absence requires exact named JSON", () => {
    const { box, result } = readFormula([], null, {
      token: "etanhey/layers/.fixture", inventory: "jq\n",
      json: JSON.stringify({ formulae: [{
        name: ".fixture", full_name: "etanhey/layers/.fixture", installed: [], linked_keg: null,
      }], casks: [] }),
    });
    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toBe("");
    expect(decode(result.stderr)).toBe("");
    expect(brewCalls(box).trim().split("\n")).toEqual([
      "list --formula -1", "info --json=v2 --formula etanhey/layers/.fixture",
    ]);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  for (const [label, options] of [
    ["failed empty inventory", { inventory: "", inventoryStatus: 1 }],
    ["failed partial inventory", { inventory: "jq\n", inventoryStatus: 42 }],
    ["malformed inventory", { inventory: "Error: inventory unavailable\n" }],
    ["qualified inventory entry", { inventory: "other/tap/voicelayer\n" }],
    ["duplicate inventory", { inventory: "jq\njq\n" }],
    ["invalid token", { inventory: "", token: "etanhey/voicelayer" }],
  ] satisfies Array<[string, { inventory: string; inventoryStatus?: number; token?: string }]>) {
    test(`active formula rejects ${label} without hiding it as absence`, () => {
      const { box, result } = readFormula([], null, options);
      expect(result.exitCode).toBe(1);
      expect(decode(result.stdout)).toBe("");
      expect(decode(result.stderr)).toContain("active formula identity");
      expect(brewCalls(box).trim()).toBe("list --formula -1");
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  test("active formula explicit seam still supports an empty version without Brew", () => {
    const box = sandbox({});
    const result = runInLib(box, 'bcs_formula_version etanhey/layers/voicelayer', {
      BREW_CASK_SYNC_TEST_FORMULA_VERSION: "",
      BREW_CASK_SYNC_BREW_BIN: "/nonexistent/voicelayer-test-brew",
    });
    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout).trim()).toBe("");
    expect(brewCalls(box)).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  for (const [label, versions, linked, options] of [
    ["unlinked", ["2.2.54"], null, {}],
    ["stale link", ["2.2.54"], "2.2.50", {}],
    ["ambiguous installed identity", ["2.2.54", "2.2.54"], "2.2.54", {}],
    ["query failure with valid stdout", ["2.2.54"], "2.2.54", { queryStatus: 42 }],
    ["unavailable query with an existing rack", ["2.2.54"], "2.2.54", { queryStatus: 1 }],
    ["unavailable query before JSON with an existing rack", ["2.2.54"], "2.2.54", { queryStatus: 1, json: "" }],
    ["malformed JSON", [], null, { json: "{" }],
    ["missing schema", [], null, { json: '{"formulae":[{}]}' }],
    ["missing linked field", [], null, { json: JSON.stringify({ formulae: [{
      name: "voicelayer", full_name: "etanhey/layers/voicelayer", installed: [],
    }] }) }],
    ["ambiguous formulae", [], null, { json: '{"formulae":[{},{}]}' }],
    ["wrong tap", [], null, { json: JSON.stringify({ formulae: [{
      name: "voicelayer", full_name: "other/tap/voicelayer", installed: [], linked_keg: null,
    }] }) }],
  ] satisfies Array<[string, string[], string | null, { json?: string; queryStatus?: number }]>) {
    test(`active formula rejects ${label} without an absent result`, () => {
      const { result } = readFormula(versions, linked, options);
      expect(result.exitCode).toBe(1);
      expect(decode(result.stdout)).toBe("");
      expect(decode(result.stderr)).toContain("active formula identity");
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  test("active formula missing Brew remains distinct from absence", () => {
    const box = sandbox({});
    const result = runInLib(box, [
      "unset BREW_CASK_SYNC_TEST_FORMULA_VERSION",
      "bcs_formula_version etanhey/layers/voicelayer",
    ].join("\n"), { BREW_CASK_SYNC_BREW_BIN: join(box.root, "missing-brew") });
    expect(result.exitCode).toBe(2);
    expect(decode(result.stdout)).toBe("");
    expect(brewCalls(box)).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

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
    }, SUBPROCESS_TEST_TIMEOUT_MS);
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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the stale registration is moved aside, never deleted", () => {
    const box = sandbox({ appVersion: "2.2.5", registeredVersion: "2.1.10" });
    sync(box);

    const kept = readdirSync(box.backupRoot);
    expect(kept.length).toBe(1);
    expect(kept[0]).toContain("voicebar-caskroom-");
    expect(existsSync(join(box.backupRoot, kept[0]!, "2.1.10"))).toBe(true);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a hand-placed unmanaged app is adopted in place", () => {
    const box = sandbox({ appVersion: "2.2.6", offeredVersion: "2.2.6" });
    const result = sync(box);

    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toContain("drift detected (unmanaged)");
    expect(brewCalls(box)).toContain(`install --cask --force ${token}`);
    expect(registeredVersions(box)).toEqual(["2.2.6"]);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a machine with nothing installed gets a plain install", () => {
    const box = sandbox({ offeredVersion: "2.2.6" });
    const result = sync(box);

    expect(result.exitCode).toBe(0);
    expect(brewCalls(box)).toContain(`install --cask ${token}`);
    expect(brewCalls(box)).not.toContain("--force");
    expect(installedAppVersion(box)).toBe("2.2.6");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

describe("brew-cask-sync environment contract", () => {
  test("the bundle version is readable without any macOS plist tooling", () => {
    // CI is ubuntu-latest, where /usr/libexec/PlistBuddy does not exist. When
    // reading the version was Darwin-only, every bundle read as "no app", which
    // collapsed all five drift states and turned this whole suite red in CI
    // while it passed locally. Pin the portable path so that cannot recur.
    const box = sandbox({ appVersion: "2.2.6" });
    const result = runInLib(box, `bcs_app_bundle_version "${box.appPath}"`, {
      BREW_CASK_SYNC_PLIST_BUDDY: "/nonexistent/PlistBuddy",
      BREW_CASK_SYNC_PLUTIL: "nonexistent-plutil",
    });

    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout).trim()).toBe("2.2.6");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("drift is still detected correctly with no plist tooling", () => {
    const box = sandbox({ appVersion: "2.2.5", registeredVersion: "2.1.10" });
    const result = runInLib(box, `bcs_drift_state ${token} "${box.appPath}"`, {
      BREW_CASK_SYNC_PLIST_BUDDY: "/nonexistent/PlistBuddy",
      BREW_CASK_SYNC_PLUTIL: "nonexistent-plutil",
    });

    expect(decode(result.stdout).trim()).toBe("version-drift");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a tapped token with no readable offer stops before touching anything", () => {
    // Tap missing, half-cloned, or renamed. Without this guard the final
    // post-condition is skipped and bcs_sync_cask returns 0 having verified
    // nothing -- a silent green on the exact state it exists to survive.
    const box = sandbox({ appVersion: "2.2.6", registeredVersion: "2.2.6" });
    rmSync(join(box.tapRepo, "Casks", "voicebar.rb"), { force: true });
    const result = sync(box);

    expect(result.exitCode).toBe(1);
    expect(decode(result.stderr)).toContain("no readable version");
    expect(decode(result.stderr)).toContain("Nothing has been changed");
    expect(brewCalls(box)).not.toContain("install --cask");
    expect(brewCalls(box)).not.toContain("upgrade --cask");
    expect(existsSync(box.backupRoot)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the tap is refreshed with an explicit remote and branch", () => {
    const box = sandbox({});
    // isolation-exempt: fixtureGitEnv retains current isolation keys while removing every inherited Git repository selector
    expect(Bun.spawnSync(["git", "init", "-q", box.tapRepo], { stderr: "ignore", env: fixtureGitEnv() }).exitCode).toBe(0);
    expect(readFileSync(join(box.tapRepo, ".git/config"), "utf8")).toContain("[core]");
    const result = runInLib(box, "bcs_tap_update etanhey/layers main");

    // There is no `origin` in the sandbox; the shape of the call is the point.
    expect(decode(result.stdout)).toContain("pull --ff-only origin main");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("an untapped tap is tapped rather than pulled", () => {
    const box = sandbox({});
    rmSync(box.tapRepo, { recursive: true, force: true });
    const result = runInLib(box, "bcs_tap_update etanhey/layers main");

    expect(result.exitCode).toBe(0);
    expect(brewCalls(box)).toContain("tap etanhey/layers");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  // zsh is not installed on the ubuntu-latest CI runner. The point of this test
  // is the M1's non-interactive zsh, so skipping where there is no zsh keeps it
  // meaningful on a Mac instead of failing for the wrong reason in CI.
  const hasZsh = Bun.spawnSync(["which", "zsh"], { env: process.env, stdout: "ignore", stderr: "ignore" })
    .exitCode === 0;

  test.skipIf(!hasZsh)("the library works when sourced from zsh, not just bash", () => {
    // The M1's non-interactive ssh shell is zsh, where `declare -F <name>`
    // succeeds for an UNDEFINED function -- the bash idiom silently calls a
    // missing run_cmd. Caught on the real M1 on 2026-08-19.
    const box = sandbox({ appVersion: "2.2.6", registeredVersion: "2.2.6" });
    // isolation-exempt: fixtureGitEnv retains current isolation keys while removing every inherited Git repository selector
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
          ...fixtureGitEnv(),
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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  // A machine with no Homebrew at all: Linux CI, or a Mac before brew is
  // installed. bcs_sync_cask already short-circuits at its entry; its callers
  // make follow-up brew calls of their own, and those have to survive too.
  function runWithoutBrew(body: string) {
    // isolation-exempt: fixtureGitEnv retains current isolation keys while removing every inherited Git repository selector
    return Bun.spawnSync(
      [
        "bash",
        "-c",
        [
          `. "${syncLib}"`,
          "bcs_brew_bin() { return 1; }",
          body,
        ].join("\n"),
      ],
      { cwd: repoRoot, stdout: "pipe", stderr: "pipe", env: { ...fixtureGitEnv() } },
    );
  }

  test("a simulated brew call on a brew-less machine prints instead of dying", () => {
    const result = runWithoutBrew(
      [
        "bcs_caller_simulates_commands() { return 0; }",
        "run_cmd() { printf '+ %s\\n' \"$*\"; }",
        `bcs_brew_run reinstall --cask ${token}`,
      ].join("\n"),
    );

    expect(result.exitCode).toBe(0);
    expect(decode(result.stdout)).toContain(`reinstall --cask ${token}`);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a real brew call on a brew-less machine fails loudly instead of silently", () => {
    const result = runWithoutBrew(
      [
        "run_cmd() { printf '+ %s\\n' \"$*\"; \"$@\"; }",
        `bcs_brew_run reinstall --cask ${token}`,
      ].join("\n"),
    );

    expect(result.exitCode).not.toBe(0);
    expect(decode(result.stderr)).toContain("Homebrew not found");
    expect(decode(result.stdout)).not.toContain(`reinstall --cask ${token}`);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
