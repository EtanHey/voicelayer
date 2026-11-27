import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";

// Release-speed plan, change 4: publish.yml skips the audio tool install and `bun test` only when
// the tag is a proof-only descendant of a build commit whose canonical CI run really executed `Run tests`. Any
// doubt prints tests_proven=false (the suite runs as before). The GitHub call is a fake `gh`.

const repoRoot = new URL("../..", import.meta.url).pathname;
const script = join(repoRoot, "scripts", "publish_tests_proven.py");

let dir: string;
let source: string;
beforeEach(() => {
  dir = mkdtempSync(join(bundleFixtureRoot(), "ptp-"));
  source = join(dir, "source");
  mkdirSync(source);
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

// GIT_CEILING_DIRECTORIES: never let a fixture git call walk up into the enclosing checkout.
const gitEnv = { ...process.env, GIT_CEILING_DIRECTORIES: bundleFixtureRoot(), GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" };
function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", source, "-c", "commit.gpgsign=false", ...args], { stdout: "pipe", stderr: "pipe", env: gitEnv });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.toString().trim();
}
function put(path: string, text: string) {
  mkdirSync(dirname(join(source, path)), { recursive: true });
  writeFileSync(join(source, path), text);
}
function commitAll(message: string) {
  git("add", "-A");
  git("commit", "-q", "-m", message);
  return git("rev-parse", "HEAD");
}
/** build commit, then a release commit (`extra` files besides the proof); returns the build SHA. */
function history(extra: Record<string, string> = {}, tag = "v2.4.7") {
  git("init", "-q", "-b", "main");
  put("src/tts.ts", "export {};\n");
  const build = commitAll("build");
  put(`release-proofs/${tag}.json`, JSON.stringify({ release: { gitCommit: build } }));
  for (const [path, text] of Object.entries(extra)) put(path, text);
  commitAll("release proof");
  return build;
}

/** What GitHub says about CI for the build commit. */
type Ci = { runs?: unknown[] | null; jobs?: unknown[] };
const goodRun = (build: string, over: Record<string, unknown> = {}) => ({
  id: 4242, head_sha: build, path: ".github/workflows/ci.yml", status: "completed", conclusion: "success",
  repository: { full_name: "EtanHey/voicelayer" }, head_repository: { full_name: "EtanHey/voicelayer" }, ...over,
});
const step = (name: string, conclusion: string) => ({ name, status: "completed", conclusion });
/** `test` job where `Run tests` really ran. */
const realTestJob = { name: "test", status: "completed", conclusion: "success", steps: [step("Set up job", "success"), step("Run tests", "success"), step("Type check", "success")] };
/** What the release-only CI shortcut emits: a green job named `test` with every real step skipped. */
const shortcutJob = { name: "test", status: "completed", conclusion: "success", steps: [step("Release-only PR, required job passes without running", "success"), step("Run tests", "skipped"), step("Type check", "skipped")] };

/** A fake gh that answers the workflow-runs call and the run-jobs call, or fails. */
function fakeGh(ci: Ci | null) {
  const path = join(dir, "gh");
  const runs = JSON.stringify({ workflow_runs: ci?.runs ?? [] });
  const jobs = JSON.stringify({ jobs: ci?.jobs ?? [] });
  writeFileSync(join(dir, "runs.json"), runs);
  writeFileSync(join(dir, "jobs.json"), jobs);
  writeFileSync(path, ci === null
    ? "#!/bin/sh\necho 'HTTP 403' >&2\nexit 1\n"
    : `#!/bin/sh\necho "$@" >> "${join(dir, "gh-args")}"\ncase "$*" in\n  *"/jobs"*) cat "${join(dir, "jobs.json")}" ;;\n  *"/runs"*) cat "${join(dir, "runs.json")}" ;;\n  *) echo '{}' ;;\nesac\n`);
  chmodSync(path, 0o755);
  return path;
}
/** The usual good evidence for `build`. */
const ciFor = (build: string, over: Partial<Ci> = {}): Ci => ({ runs: [goodRun(build)], jobs: [realTestJob], ...over });
const run = (gh: string, tag = "v2.4.7") => {
  const out = join(dir, "github-output");
  rmSync(out, { force: true }); // GITHUB_OUTPUT is append-only; each run starts from an empty file
  const r = Bun.spawnSync(["python3", "-B", script, "--source", source, "--tag", tag, "--repo", "EtanHey/voicelayer", "--github-output", out], {
    stdout: "pipe", stderr: "pipe", env: { ...process.env, GH: gh },
  });
  let output = "";
  try { output = readFileSync(out, "utf8"); } catch { /* none written */ }
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString(), output };
};
const FALSE = "tests_proven=false\n";

describe("publish_tests_proven.py: any doubt runs the suite", () => {
  test("the CI shortcut's green `test` job (Run tests SKIPPED) is not evidence that bun test ran", () => {
    const build = history();
    const r = run(fakeGh(ciFor(build, { jobs: [shortcutJob] })));
    expect(r.output).toBe(FALSE);
    expect(r.out).toContain("RUN bun test");
    expect(r.out).toContain("`Run tests` succeeding");
  });

  test("a green check merely named `test` with no `Run tests` step, or a failed one, is not evidence", () => {
    const build = history();
    for (const job of [
      { name: "test", status: "completed", conclusion: "success", steps: [step("Type check", "success")] },
      { name: "test", status: "completed", conclusion: "success", steps: [step("Run tests", "failure")] },
      { name: "test", status: "completed", conclusion: "success", steps: [] },
      { name: "test", status: "completed", conclusion: "failure", steps: [step("Run tests", "success")] },
      { name: "Swift (VoiceBar)", status: "completed", conclusion: "success", steps: [step("Run tests", "success")] },
    ]) expect(run(fakeGh(ciFor(build, { jobs: [job] }))).output).toBe(FALSE);
  });

  test("a run of another workflow, another commit, a fork, or an unfinished run is not evidence", () => {
    const build = history();
    for (const over of [
      { path: ".github/workflows/other.yml" },
      { head_sha: "2222222222222222222222222222222222222222" },
      { head_repository: { full_name: "someone/voicelayer" } },
      { repository: { full_name: "someone/voicelayer" } },
      { status: "in_progress" },
    ]) expect(run(fakeGh(ciFor(build, { runs: [goodRun(build, over)] }))).output).toBe(FALSE);
    expect(run(fakeGh({ runs: [], jobs: [] })).output).toBe(FALSE);
  });

  test("a tag that also changes code after the proven build runs the suite", () => {
    const build = history({ "src/tts.ts": "export const sneaked = 1;\n" });
    const r = run(fakeGh(ciFor(build)));
    expect(r.output).toBe(FALSE);
    expect(r.out).toContain("not a proof-only descendant");
    expect(r.out).toContain("src/tts.ts");
  });

  test("a tag that changes proof-hosts.json runs the suite", () => {
    const build = history({ "release-proofs/proof-hosts.json": "{}\n" });
    expect(run(fakeGh(ciFor(build))).output).toBe(FALSE);
  });

  test("a bun-discoverable test file under release-proofs/ runs the suite", () => {
    const build = history({ "release-proofs/sneaky.test.ts": "import { test } from 'bun:test'; test('x', () => {});\n" });
    const r = run(fakeGh(ciFor(build)));
    expect(r.output).toBe(FALSE);
    expect(r.out).toContain("sneaky.test.ts");
  });

  test("the GitHub API failing runs the suite", () => {
    history();
    const r = run(fakeGh(null));
    expect(r.output).toBe(FALSE);
    expect(r.out).toContain("cannot read CI evidence");
  });

  test("an answer that is not workflow-runs JSON runs the suite", () => {
    const build = history();
    expect(run(fakeGh(ciFor(build, { runs: "nope" as unknown as unknown[] }))).output).toBe(FALSE);
  });

  test("a missing or malformed proof, or a build that is not a full SHA, runs the suite", () => {
    git("init", "-q", "-b", "main");
    put("src/tts.ts", "export {};\n");
    commitAll("no proof at all");
    expect(run(fakeGh(ciFor("0".repeat(40)))).output).toBe(FALSE);
    put("release-proofs/v2.4.7.json", JSON.stringify({ release: { gitCommit: "abc123" } }));
    commitAll("short sha");
    expect(run(fakeGh(ciFor("0".repeat(40)))).output).toBe(FALSE);
    put("release-proofs/v2.4.7.json", "not json");
    commitAll("garbage");
    expect(run(fakeGh(ciFor("0".repeat(40)))).output).toBe(FALSE);
  });

  test("a proof that is a symlink (git mode 120000) is not read: the suite runs", () => {
    git("init", "-q", "-b", "main");
    put("src/tts.ts", "export {};\n");
    const build = commitAll("build");
    put("elsewhere/proof.json", JSON.stringify({ release: { gitCommit: build } }));
    mkdirSync(join(source, "release-proofs"), { recursive: true });
    symlinkSync("../elsewhere/proof.json", join(source, "release-proofs", "v2.4.7.json"));
    commitAll("release: proof as a symlink");
    // The target is committed, so a working-tree read would find a valid proof; the blob is a symlink.
    const r = run(fakeGh(ciFor(build)));
    expect(r.output).toBe(FALSE);
    expect(r.out).toContain("not a regular committed file");
  });

  test("a tag spelling that is not a release tag (refs/tags/..., path tricks) runs the suite", () => {
    const build = history();
    for (const tag of ["refs/tags/v2.4.7", "../v2.4.7", "v2.4", "main"]) expect(run(fakeGh(ciFor(build)), tag).output).toBe(FALSE);
  });

  test("a proven build that is not an ancestor of the tagged commit runs the suite", () => {
    git("init", "-q", "-b", "main");
    put("src/tts.ts", "export {};\n");
    commitAll("one");
    git("checkout", "-q", "--orphan", "unrelated");
    put("src/other.ts", "export {};\n");
    const other = commitAll("unrelated history");
    git("checkout", "-q", "main");
    put("release-proofs/v2.4.7.json", JSON.stringify({ release: { gitCommit: other } }));
    commitAll("proof naming an unrelated commit");
    expect(run(fakeGh(ciFor(other))).output).toBe(FALSE);
  });
});

describe("publish_tests_proven.py: skip only when both facts hold", () => {
  test("proof-only tag over a build whose canonical CI run really executed `Run tests` skips the suite", () => {
    const build = history();
    const r = run(fakeGh(ciFor(build)));
    expect(r.code).toBe(0);
    expect(r.output).toBe("tests_proven=true\n");
    expect(r.out).toContain("SKIP bun test");
    expect(r.out).toContain("ran `Run tests` successfully");
    // it asked GitHub for exactly that build's ci.yml runs on this repo, then that run's jobs
    const args = readFileSync(join(dir, "gh-args"), "utf8");
    expect(args).toContain(`repos/EtanHey/voicelayer/actions/workflows/ci.yml/runs?head_sha=${build}`);
    expect(args).toContain("repos/EtanHey/voicelayer/actions/runs/4242/jobs");
  });

  test("a later green run whose Run tests ran wins over an earlier shortcut run", () => {
    const build = history();
    const r = run(fakeGh(ciFor(build, { runs: [goodRun(build, { id: 1 }), goodRun(build, { id: 2 })], jobs: [shortcutJob, realTestJob] })));
    expect(r.output).toBe("tests_proven=true\n");
  });

  test("an added or modified proof file beside it (notes under release-proofs/) still counts as proof-only", () => {
    const build = history({ "release-proofs/notes.txt": "x\n" });
    expect(run(fakeGh(ciFor(build))).output).toBe("tests_proven=true\n");
  });
});

describe("wiring", () => {
  test("the script never fails the job on a doubt: an unexpected error is a `false`, not a crash", () => {
    // a source directory that is not a git repository at all
    const r = Bun.spawnSync(["python3", "-B", script, "--source", join(dir, "nope"), "--tag", "v2.4.7", "--repo", "x/y", "--github-output", join(dir, "o")], {
      stdout: "pipe", stderr: "pipe", env: process.env,
    });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(dir, "o"), "utf8")).toBe("tests_proven=false\n");
  });
});
