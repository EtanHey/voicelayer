import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { dirname, join } from "path";

// Release-speed plan, change 4: publish.yml skips the audio tool install and `bun test` only when
// the tag is a proof-only descendant of a build commit that has a green `test` check run. Any
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

/** A fake gh that answers the check-runs call with `body` (or fails). */
function fakeGh(body: unknown | null) {
  const path = join(dir, "gh");
  writeFileSync(path, body === null
    ? "#!/bin/sh\necho 'HTTP 403' >&2\nexit 1\n"
    : `#!/bin/sh\necho "$@" > "${join(dir, "gh-args")}"\ncat <<'JSON'\n${JSON.stringify(body)}\nJSON\n`);
  chmodSync(path, 0o755);
  return path;
}
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
const green = { check_runs: [{ name: "test", status: "completed", conclusion: "success", app: { slug: "github-actions" } }] };

describe("publish_tests_proven.py: any doubt runs the suite", () => {
  test("a build whose test job FAILED runs the suite", () => {
    history();
    const r = run(fakeGh({ check_runs: [{ ...green.check_runs[0], conclusion: "failure" }] }));
    expect(r.output).toBe("tests_proven=false\n");
    expect(r.out).toContain("RUN bun test");
    expect(r.out).toContain("no green `test` check run");
  });

  test("a build whose test job is still running, cancelled or from another app runs the suite", () => {
    history();
    for (const run_ of [
      { ...green.check_runs[0], status: "in_progress", conclusion: null },
      { ...green.check_runs[0], conclusion: "cancelled" },
      { ...green.check_runs[0], app: { slug: "someone-else" } },
      { ...green.check_runs[0], name: "Swift (VoiceBar)" },
    ]) expect(run(fakeGh({ check_runs: [run_] })).output).toBe("tests_proven=false\n");
    expect(run(fakeGh({ check_runs: [] })).output).toBe("tests_proven=false\n");
  });

  test("a tag that also changes code after the proven build runs the suite", () => {
    history({ "src/tts.ts": "export const sneaked = 1;\n" });
    const r = run(fakeGh(green));
    expect(r.output).toBe("tests_proven=false\n");
    expect(r.out).toContain("not a proof-only descendant");
    expect(r.out).toContain("src/tts.ts");
  });

  test("a tag that changes proof-hosts.json, or deletes a proof, runs the suite", () => {
    history({ "release-proofs/proof-hosts.json": "{}\n" });
    expect(run(fakeGh(green)).output).toBe("tests_proven=false\n");
  });

  test("the GitHub API failing runs the suite", () => {
    history();
    const r = run(fakeGh(null));
    expect(r.output).toBe("tests_proven=false\n");
    expect(r.out).toContain("cannot read check runs");
  });

  test("an answer that is not check-runs JSON runs the suite", () => {
    history();
    expect(run(fakeGh({ unexpected: true })).output).toBe("tests_proven=false\n");
    expect(run(fakeGh({ check_runs: "nope" })).output).toBe("tests_proven=false\n");
  });

  test("a missing or malformed proof, or a build that is not a full SHA, runs the suite", () => {
    git("init", "-q", "-b", "main");
    put("src/tts.ts", "export {};\n");
    commitAll("no proof at all");
    expect(run(fakeGh(green)).output).toBe("tests_proven=false\n");
    put("release-proofs/v2.4.7.json", JSON.stringify({ release: { gitCommit: "abc123" } }));
    commitAll("short sha");
    expect(run(fakeGh(green)).output).toBe("tests_proven=false\n");
    put("release-proofs/v2.4.7.json", "not json");
    commitAll("garbage");
    expect(run(fakeGh(green)).output).toBe("tests_proven=false\n");
  });

  test("a tag spelling that is not a release tag (refs/tags/..., path tricks) runs the suite", () => {
    history();
    for (const tag of ["refs/tags/v2.4.7", "../v2.4.7", "v2.4", "main"]) expect(run(fakeGh(green), tag).output).toBe("tests_proven=false\n");
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
    expect(run(fakeGh(green)).output).toBe("tests_proven=false\n");
  });
});

describe("publish_tests_proven.py: skip only when both facts hold", () => {
  test("proof-only tag over a build with a green `test` check run skips the suite", () => {
    const build = history();
    const r = run(fakeGh(green));
    expect(r.code).toBe(0);
    expect(r.output).toBe("tests_proven=true\n");
    expect(r.out).toContain("SKIP bun test");
    expect(r.out).toContain(build.slice(0, 8));
    // it asked GitHub for exactly that build's `test` check runs, on this repo
    const args = readFileSync(join(dir, "gh-args"), "utf8");
    expect(args).toContain(`repos/EtanHey/voicelayer/commits/${build}/check-runs`);
    expect(args).toContain("check_name=test");
  });

  test("an added or modified proof file beside it (notes under release-proofs/) still counts as proof-only", () => {
    history({ "release-proofs/notes.txt": "x\n" });
    expect(run(fakeGh(green)).output).toBe("tests_proven=true\n");
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
