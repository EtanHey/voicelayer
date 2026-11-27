import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { isProofOnlyPath } from "../../scripts/t3-optf5-proof";

// The pre-push hook and required PR checks share the release gate's path allow-list.
const repoRoot = new URL("../..", import.meta.url).pathname;
const classifier = join(repoRoot, "scripts", "release_only_diff.py");

function py(args: string[], opts: { cwd?: string; input?: string } = {}) {
  const r = Bun.spawnSync(["python3", "-B", classifier, ...args], {
    cwd: opts.cwd ?? repoRoot, stdout: "pipe", stderr: "pipe", stdin: opts.input === undefined ? undefined : new TextEncoder().encode(opts.input),
    env: process.env,
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

describe("one allow-list: the Python classifier equals the release gate's isProofOnlyPath", () => {
  const paths = [
    "release-proofs/v2.4.7.json",
    "release-proofs/v2.4.7-rc.1.json",
    "release-proofs/nested/dir/file.txt",
    "release-proofs/proof-hosts.json", // reviewed code: never release-only
    "release-proofs/proof-hosts.json.bak",
    "release-proofs/",
    "release-proofs",
    "release-proofs-evil/v2.4.7.json",
    "xrelease-proofs/v2.4.7.json",
    "src/release-proofs/v2.4.7.json",
    "package.json",
    "bun.lock",
    "release-proofs/../package.json",
    "docs/voicebar-release-runbook.md",
    ".githooks/pre-push",
    ".github/workflows/publish.yml",
    "scripts/release_only_diff.py",
    "Release-Proofs/v2.4.7.json",
    // files the root `bun test` discovers by name: code that would run in the suite being skipped
    "release-proofs/sneaky.test.ts",
    "release-proofs/sub/dir/sneaky.spec.js",
    "release-proofs/a_test.tsx",
    "release-proofs/a_spec.mjs",
    "release-proofs/A.TEST.TS",
    "release-proofs/x.test.cts",
    "release-proofs/notes.test.md", // not a bun-discoverable extension: data
    "release-proofs/contest.json",
    "release-proofs/latest.ts", // a plain script is not discovered by `bun test` (still never read as a proof)
  ];

  test("every path gets the same answer from both implementations", () => {
    const r = py(["--classify-paths"], { input: paths.join("\n") });
    expect(r.code).toBe(0);
    expect(r.out.trim().split("\n")).toEqual(paths.map((p) => (isProofOnlyPath(p) ? "allowed" : "refused")));
  });

  test("a file the root bun test discovers by name is never release-only", () => {
    for (const path of ["release-proofs/sneaky.test.ts", "release-proofs/sub/x.spec.js", "release-proofs/a_test.tsx", "release-proofs/a_spec.mjs", "release-proofs/A.TEST.TS"]) {
      expect(isProofOnlyPath(path), path).toBe(false);
    }
    expect(isProofOnlyPath("release-proofs/v2.4.7.json")).toBe(true);
  });

  test("the allow-list is exactly release-proofs/ minus proof-hosts.json (and nothing wider, e.g. package.json)", () => {
    expect(isProofOnlyPath("release-proofs/v9.9.9.json")).toBe(true);
    expect(isProofOnlyPath("release-proofs/proof-hosts.json")).toBe(false);
    expect(isProofOnlyPath("package.json")).toBe(false);
    expect(isProofOnlyPath("bun.lock")).toBe(false);
  });
});

// ---- the classifier against real git history ------------------------------------------------

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(bundleFixtureRoot(), "relonly-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

// GIT_CEILING_DIRECTORIES: a fixture directory that is not (yet) a repository must fail, never fall through
// to the enclosing checkout and run `git add -A` / `git commit` there.
const gitEnv = { ...process.env, GIT_CEILING_DIRECTORIES: bundleFixtureRoot(), GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" };
function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", dir, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", ...args], {
    stdout: "pipe", stderr: "pipe", env: gitEnv,
  });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.toString().trim();
}
function put(path: string, text = "x\n") {
  mkdirSync(dirname(join(dir, path)), { recursive: true });
  writeFileSync(join(dir, path), text);
}
function commit(message: string) {
  git("add", "-A");
  git("commit", "-q", "-m", message);
  return git("rev-parse", "HEAD");
}
/** Base commit with code, a package version, a lockfile and the proof host list; returns it. */
function base() {
  git("init", "-q", "-b", "main");
  put("package.json", JSON.stringify({ name: "voicelayer-mcp", version: "2.4.6" }));
  put("bun.lock", "lock\n");
  put("src/tts.ts", "export {};\n");
  put("release-proofs/proof-hosts.json", "{}\n");
  put("release-proofs/v2.4.6.json", "{}\n");
  return commit("base");
}
function classify(from: string, to = "HEAD") {
  return py(["--repo", dir, "--base", from, "--head", to, "--github-output", join(dir, ".out")]);
}
const outFile = () => { try { return readFileSync(join(dir, ".out"), "utf8"); } catch { return ""; } };

describe("release_only_diff.py on a real diff (safe side first)", () => {
  test("a code change plus a proof is NOT release-only: everything runs", () => {
    const b = base();
    put("release-proofs/v2.4.7.json");
    put("src/tts.ts", "export const changed = 1;\n");
    commit("proof plus code");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("src/tts.ts is outside release-proofs/");
    expect(outFile()).toBe("release_only=false\n");
  });

  test("a package.json version bump alone is NOT release-only (the gate's allow-list has no package.json)", () => {
    const b = base();
    put("package.json", JSON.stringify({ name: "voicelayer-mcp", version: "2.4.7" }));
    commit("bump");
    expect(classify(b).code).toBe(1);
  });

  test("a lockfile change alone is NOT release-only", () => {
    const b = base();
    put("bun.lock", "lock2\n");
    commit("lock");
    expect(classify(b).code).toBe(1);
  });

  test("a workflow, hook or classifier edit with a proof is NOT release-only", () => {
    base();
    for (const path of [".github/workflows/ci.yml", ".githooks/pre-push", "scripts/release_only_diff.py", "scripts/t3-optf5-proof.ts"]) {
      const b = git("rev-parse", "HEAD");
      put("release-proofs/v2.4.7.json", `${path}\n`);
      put(path, "changed\n");
      commit(`proof plus ${path}`);
      expect(classify(b).code, path).toBe(1);
    }
  });

  test("changing proof-hosts.json is NOT release-only", () => {
    const b = base();
    put("release-proofs/proof-hosts.json", '{"hosts":[]}\n');
    commit("hosts");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("proof-hosts.json");
  });

  test("deleting a proof is NOT release-only", () => {
    const b = base();
    rmSync(join(dir, "release-proofs/v2.4.6.json"));
    commit("delete proof");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("only added or modified files");
  });

  test("moving a file into release-proofs/ is NOT release-only (the source path is a deletion)", () => {
    const b = base();
    mkdirSync(join(dir, "release-proofs"), { recursive: true });
    renameSync(join(dir, "src/tts.ts"), join(dir, "release-proofs/v2.4.7.json"));
    commit("move");
    expect(classify(b).code).toBe(1);
  });

  test("a new symlink under release-proofs/ is NOT release-only (S4: the gate would follow it)", () => {
    const b = base();
    mkdirSync(join(dir, "release-proofs"), { recursive: true });
    symlinkSync("../src/tts.ts", join(dir, "release-proofs/v2.4.7.json"));
    commit("symlink");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("git mode 120000");
  });

  test("editing an existing proof into a symlink, or a symlink target, is NOT release-only", () => {
    const b = base();
    rmSync(join(dir, "release-proofs/v2.4.6.json"));
    symlinkSync("../src/tts.ts", join(dir, "release-proofs/v2.4.6.json"));
    commit("proof became a symlink");
    expect(classify(b).code).toBe(1); // status T (type change) / mode 120000
  });

  test("a submodule (gitlink, mode 160000) under release-proofs/ is NOT release-only", () => {
    const b = base();
    git("update-index", "--add", "--cacheinfo", `160000,${b},release-proofs/sub`);
    git("commit", "-q", "-m", "gitlink");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("git mode 160000");
  });

  test("an executable file under release-proofs/ is NOT release-only", () => {
    const b = base();
    put("release-proofs/v2.4.7.json");
    chmodSync(join(dir, "release-proofs/v2.4.7.json"), 0o755);
    commit("executable");
    expect(classify(b).err).toContain("git mode 100755");
  });

  test("r2 #5: removing the executable bit from a proof is NOT release-only", () => {
    base();
    const proof = join(dir, "release-proofs/v2.4.6.json");
    chmodSync(proof, 0o755);
    const executable = commit("make proof executable");
    chmodSync(proof, 0o644);
    commit("remove executable bit");
    const r = classify(executable);
    expect(r.code).toBe(1);
    expect(outFile()).toBe("release_only=false\n");
  });

  test("a bun test file under release-proofs/ is NOT release-only (S5: it would skip its own run)", () => {
    const b = base();
    put("release-proofs/sneaky.test.ts", "import { test } from 'bun:test'; test('x', () => {});\n");
    commit("test file");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("sneaky.test.ts");
  });

  test("--ancestor: a base that is not an ancestor of head cannot be classified (B1: a rewrite that drops code)", () => {
    const b = base();
    git("checkout", "-q", "-b", "feat");
    put("src/tts.ts", "export const feature = 1;\n");
    const featureTip = commit("feature code");
    git("checkout", "-q", "main");
    put("release-proofs/v2.4.7.json");
    commit("proof only, built on main");
    // Three-dot (merge base) makes the rewrite look proof-only; it is not: it drops the feature code.
    expect(classify(featureTip).code).toBe(0);
    const strict = py(["--repo", dir, "--base", featureTip, "--head", "HEAD", "--ancestor"]);
    expect(strict.code).toBe(2);
    expect(strict.err).toContain("not an ancestor");
    // and the same proof on top of the feature tip IS release-only under --ancestor
    rmSync(join(dir, ".out"), { force: true }); // the answer file classify() wrote; keep it out of the commit
    git("checkout", "-q", "feat");
    put("release-proofs/v2.4.7.json");
    commit("proof on top of the feature");
    const onTop = py(["--repo", dir, "--base", featureTip, "--head", "HEAD", "--ancestor"]);
    expect(onTop.err).toContain("RELEASE-ONLY");
    expect(onTop.code).toBe(0);
    void b;
  });

  test("an empty diff is NOT release-only", () => {
    const b = base();
    git("commit", "-q", "--allow-empty", "-m", "empty");
    const r = classify(b);
    expect(r.code).toBe(1);
    expect(r.err).toContain("empty");
  });

  test("an unknown base or head cannot be classified: exit 2 and no answer written", () => {
    base();
    const r = classify("0000000000000000000000000000000000000000");
    expect(r.code).toBe(2);
    expect(r.err).toContain("run everything");
    expect(outFile()).toBe("");
  });
});

describe("release_only_diff.py on a real diff (the skip side)", () => {
  test("added and modified proofs are release-only, with the answer written for CI", () => {
    const b = base();
    put("release-proofs/v2.4.7.json");
    put("release-proofs/v2.4.6.json", '{"edited":true}\n');
    put("release-proofs/notes/readme.txt");
    commit("proofs");
    const r = classify(b);
    expect(r.err).toContain("RELEASE-ONLY");
    expect(r.code).toBe(0);
    expect(outFile()).toBe("release_only=true\n");
  });

  test("unusual file names (space, newline) are classified from the NUL-separated diff, not guessed", () => {
    const b = base();
    put("release-proofs/a b.json");
    put("release-proofs/line\nbreak.json");
    commit("odd names");
    expect(classify(b).code).toBe(0);
    put("src/x\ny.ts");
    commit("odd code name");
    expect(classify(b).code).toBe(1);
  });

  test("the diff is taken against the merge base, the way a PR's file list is", () => {
    const b = base();
    git("checkout", "-q", "-b", "side");
    put("release-proofs/v2.4.7.json");
    commit("proof on side");
    git("checkout", "-q", "main");
    put("src/tts.ts", "export const mainOnly = 1;\n");
    const mainTip = commit("main moved on");
    expect(classify(mainTip, "side").code).toBe(0); // main's own change is not part of the PR
    expect(classify(b, "main").code).toBe(1);
  });
});

// ---- workflow wiring (structure: a skipped step can never be one that was meant to run) -----

type Step = { name?: string; uses?: string; run?: string; if?: string; id?: string; "continue-on-error"?: boolean; with?: Record<string, string> };
type Job = { name?: string; needs?: string; if?: string; "runs-on"?: string; steps: Step[]; outputs?: Record<string, string> };
const workflow = (file: string) => Bun.YAML.parse(readFileSync(join(repoRoot, ".github", "workflows", file), "utf8")) as { jobs: Record<string, Job> };
const GUARD = "needs.changes.outputs.release_only";

describe("CI workflows: the required jobs short-circuit a release-only PR and run everything otherwise", () => {
  for (const [file, jobId, check] of [["ci.yml", "test", "test"], ["ci.yml", "swift", "Swift (VoiceBar)"], ["ratchet.yml", "ratchet", "ratchet"]] as const) {
    describe(`${file} › ${jobId}`, () => {
      const job = () => workflow(file).jobs[jobId];

      test("reports under the same required check name, behind the `changes` job, and still runs when `changes` fails", () => {
        expect(job().name ?? jobId).toBe(check);
        expect(job().needs).toBe("changes");
        expect(job().if).toBe("${{ !cancelled() }}"); // no answer from `changes` must mean "run", never "skipped"
      });

      test("first step is the loud success line, and EVERY other step is skipped only when release_only == 'true'", () => {
        const steps = job().steps;
        expect(steps[0].if).toBe(`${GUARD} == 'true'`);
        expect(steps[0].run).toContain("RELEASE-ONLY PR");
        for (const step of steps.slice(1)) {
          expect(step.if, `step "${step.name ?? step.uses ?? step.run}" has no release-only guard`).toContain(`${GUARD} != 'true'`);
          expect(step.if).not.toContain("== 'true'" + " ||"); // never an OR that could let a step through on a release-only PR
        }
      });
    });
  }

  test("the macOS jobs move to a hosted ubuntu runner (no macOS queue) only on a release-only PR", () => {
    const expected = "${{ needs.changes.outputs.release_only == 'true' && 'ubuntu-latest' || 'macos-26' }}";
    expect(workflow("ci.yml").jobs.swift["runs-on"]).toBe(expected);
    expect(workflow("ratchet.yml").jobs.ratchet["runs-on"]).toBe(expected);
    expect(workflow("ci.yml").jobs.test["runs-on"]).toBe("ubuntu-latest");
  });

  test("`changes`: classifier is run from the PR's BASE checkout, never from the PR's own files", () => {
    for (const file of ["ci.yml", "ratchet.yml"]) {
      const changes = workflow(file).jobs.changes;
      expect(changes.outputs?.release_only).toBe("${{ steps.classify.outputs.release_only }}");
      const trusted = changes.steps.find((s) => s.with?.path === ".trusted");
      expect(trusted?.with?.ref).toBe("${{ github.event.pull_request.base.sha }}");
      const classify = changes.steps.find((s) => s.id === "classify")!;
      expect(classify.run).toContain("python3 .trusted/scripts/release_only_diff.py");
      expect(classify.run).not.toMatch(/python3 scripts\//);
      expect(classify.if).toBe("github.event_name == 'pull_request'"); // pushes (main) never short-circuit
      expect(classify["continue-on-error"]).toBe(true); // a missing base script leaves the output empty: run everything
    }
  });

  test("the two `changes` jobs are identical, and the shared workflow text carries no bypass input", () => {
    expect(workflow("ci.yml").jobs.changes).toEqual(workflow("ratchet.yml").jobs.changes);
    for (const file of ["ci.yml", "ratchet.yml"]) {
      expect(readFileSync(join(repoRoot, ".github", "workflows", file), "utf8")).not.toMatch(/^\s+[A-Z_]*(SKIP|BYPASS|FORCE)[A-Z_]*:/m);
    }
  });

  test("other required checks are untouched: the docs.local guard still runs unconditionally", () => {
    const guard = workflow("ci.yml").jobs["docs-local-guard"];
    expect(guard.needs).toBeUndefined();
    expect(guard.steps.every((s) => s.if === undefined)).toBe(true);
  });
});
