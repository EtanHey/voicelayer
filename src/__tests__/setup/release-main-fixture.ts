import { copyFileSync, existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

// A throwaway package root for the release-lock tests: its own git repo with a bare local
// "origin" whose main holds one commit, and `scripts` linked to the real scripts so the
// real release scripts run with PACKAGE_ROOT pointing here. Never touches the real remote.
const repo = resolve(import.meta.dir, "../../..");

const gitEnv = {
  ...process.env,
  GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t",
  GIT_AUTHOR_DATE: "2026-10-18T01:00:00Z", GIT_COMMITTER_DATE: "2026-10-18T01:00:00Z",
};

export function fixtureGit(cwd: string, ...args: string[]): string {
  const r = Bun.spawnSync(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", ...args], {
    cwd, stdout: "pipe", stderr: "pipe", env: gitEnv,
  });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
  return r.stdout.toString().trim();
}

export interface MainFixture {
  root: string; // package root: a git checkout of the fixture origin
  origin: string;
  mainSha: string; // the one commit on origin/main
  /** Add a commit on a side branch (never pushed) and leave it checked out; returns its sha. */
  sideCommit(): string;
}

export function makeMainFixture(parent: string): MainFixture {
  const base = mkdtempSync(join(parent, "relmain-"));
  const origin = join(base, "origin.git");
  const root = join(base, "pkg");
  fixtureGit(base, "init", "-q", "--bare", "-b", "main", origin);
  mkdirSync(root);
  fixtureGit(root, "init", "-q", "-b", "main");
  copyFileSync(join(repo, "package.json"), join(root, "package.json"));
  // The release scripts read these from PACKAGE_ROOT; link them to the real tree, untracked.
  const linked = ["scripts", "src", "flow-bar", "release-proofs", "docs"];
  writeFileSync(join(root, ".gitignore"), linked.map((n) => `/${n}\n`).join(""));
  fixtureGit(root, "add", ".");
  fixtureGit(root, "commit", "-q", "-m", "main commit");
  fixtureGit(root, "remote", "add", "origin", origin);
  fixtureGit(root, "push", "-q", "origin", "main");
  for (const name of linked) if (existsSync(join(repo, name))) symlinkSync(join(repo, name), join(root, name));
  const mainSha = fixtureGit(root, "rev-parse", "HEAD");
  return {
    root, origin, mainSha,
    sideCommit() {
      fixtureGit(root, "checkout", "-q", "-b", "side");
      writeFileSync(join(root, "side.txt"), "side\n");
      fixtureGit(root, "add", "side.txt");
      fixtureGit(root, "commit", "-q", "-m", "side commit");
      return fixtureGit(root, "rev-parse", "HEAD");
    },
  };
}
