import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const script = join(repoRoot, "scripts", "verify-merged-prs-landed.sh");

let tempRoot = "";
let binDir = "";

function writeExecutable(name: string, body: string) {
  const path = join(binDir, name);
  writeFileSync(path, body);
  chmodSync(path, 0o755);
}

function run(options: { skipFetch?: boolean } = {}) {
  const env = {
    ...process.env,
    PATH: `${binDir}:/usr/bin:/bin`,
  };
  delete env.MERGED_PRS_SKIP_FETCH;
  if (options.skipFetch !== false) env.MERGED_PRS_SKIP_FETCH = "1";

  return Bun.spawnSync(["bash", script], {
    cwd: tempRoot,
    stdout: "pipe",
    stderr: "pipe",
    env,
  });
}

function output(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

beforeEach(() => {
  tempRoot = mkdtempSync(join(tmpdir(), "merged-pr-delivery-test-"));
  binDir = join(tempRoot, "bin");
  mkdirSync(binDir);

  writeExecutable(
    "git",
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "rev-parse --git-dir" ]]; then
  printf '%s\n' "${tempRoot}/.git"
  exit 0
fi
if [[ "$1 $2" == "rev-parse --verify" ]]; then
  printf '%s\n' "base-sha"
  exit 0
fi
if [[ "$1 $2" == "rev-parse --is-shallow-repository" ]]; then
  printf '%s\n' "false"
  exit 0
fi
if [[ "$1 $2" == "merge-base --is-ancestor" ]]; then
  [[ "$3" == "reachable-sha" ]]
  exit
fi
printf 'unexpected git call: %s\n' "$*" >&2
exit 64
`,
  );

  writeExecutable(
    "gh",
    `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "repo view" ]]; then
  printf '%s\n' 'EtanHey/voicelayer'
  exit 0
fi
if [[ "$1" == "api" ]]; then
  printf '388\treachable-sha\thttps://example.test/pull/388\tLanded PR\n'
  printf '392\torphaned-sha\thttps://example.test/pull/392\tOrphaned PR\n'
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 64
`,
  );
});

afterEach(() => {
  if (tempRoot) rmSync(tempRoot, { recursive: true, force: true });
});

describe("verify-merged-prs-landed.sh", () => {
  test("lists merged PRs whose merge commit is not reachable from origin/main", () => {
    const result = run();
    const stderr = output(result.stderr);

    expect(result.exitCode).toBe(1);
    expect(stderr).toContain("#392");
    expect(stderr).toContain("orphaned-sha");
    expect(stderr).toContain("https://example.test/pull/392");
    expect(stderr).not.toContain("#388");
    expect(stderr).toContain("1 merged PR is not reachable from origin/main");
  });

  test("passes when every merged PR merge commit is reachable", () => {
    writeExecutable(
      "gh",
      `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "repo view" ]]; then
  printf '%s\n' 'EtanHey/voicelayer'
  exit 0
fi
printf '388\treachable-sha\thttps://example.test/pull/388\tLanded PR\n'
`,
    );

    const result = run();

    expect(result.exitCode).toBe(0);
    expect(output(result.stdout)).toContain(
      "All merged PR merge commits are reachable from origin/main",
    );
    expect(output(result.stderr)).toBe("");
  });

  test("treats a missing merge object as unreachable after refreshing the base", async () => {
    writeExecutable(
      "git",
      `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "rev-parse --git-dir" ]]; then
  printf '%s\n' "${tempRoot}/.git"
  exit 0
fi
if [[ "$1 $2" == "rev-parse --verify" ]]; then
  printf '%s\n' "base-sha"
  exit 0
fi
if [[ "$1 $2" == "rev-parse --is-shallow-repository" ]]; then
  printf '%s\n' "false"
  exit 0
fi
if [[ "$1" == "fetch" ]]; then
  printf '%s\n' "$*" > "${tempRoot}/fetch.log"
  exit 0
fi
if [[ "$1 $2" == "merge-base --is-ancestor" ]]; then
  exit 128
fi
if [[ "$1 $2" == "cat-file -e" ]]; then
  exit 1
fi
printf 'unexpected git call: %s\n' "$*" >&2
exit 64
`,
    );
    writeExecutable(
      "gh",
      `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "repo view" ]]; then
  printf '%s\n' 'EtanHey/voicelayer'
  exit 0
fi
printf '199\tmissing-sha\thttps://example.test/pull/199\tMissing object PR\n'
`,
    );

    const result = run({ skipFetch: false });
    const stderr = output(result.stderr);

    expect(result.exitCode).toBe(1);
    expect(await Bun.file(join(tempRoot, "fetch.log")).text()).toContain(
      "fetch origin refs/heads/main:refs/remotes/origin/main --quiet",
    );
    expect(stderr).toContain("#199");
    expect(stderr).toContain("missing-sha");
    expect(stderr).toContain("1 merged PR is not reachable from origin/main");
  });

  test("fails closed when the repository history is shallow", () => {
    writeExecutable(
      "git",
      `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "rev-parse --git-dir" ]]; then
  printf '%s\n' "${tempRoot}/.git"
  exit 0
fi
if [[ "$1 $2" == "rev-parse --is-shallow-repository" ]]; then
  printf '%s\n' "true"
  exit 0
fi
printf 'unexpected git call: %s\n' "$*" >&2
exit 64
`,
    );

    const result = run();

    expect(result.exitCode).toBe(2);
    expect(output(result.stderr)).toContain("complete (non-shallow) Git history");
  });
});
