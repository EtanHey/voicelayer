import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

test("suite queue excludes a waiting job and releases after child exit", () => {
  const result = spawnSync("python3", ["-c", `
import fcntl, os, pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='vl-suite-queue-') as root:
    env = dict(os.environ, HOME=root)
    command = [sys.executable, sys.argv[1], '--', sys.executable, '-u', '-c',
               "print('entered', flush=True); input(); raise SystemExit(7)"]
    first = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    second = None
    try:
        assert first.stdout.readline().strip() == 'entered'
        lock = pathlib.Path(root) / '.local/state/voicelayer/heavy-suite.lock'
        with lock.open('r') as observer:
            try:
                fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise AssertionError('running suite does not hold lock')
            except BlockingIOError:
                pass
        second = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert 'WAIT' in second.stderr.readline()
        try:
            second.communicate(input='\\n', timeout=0.2)
            raise AssertionError('second suite entered before first exited')
        except subprocess.TimeoutExpired:
            pass
        first.communicate(input='\\n', timeout=5)
        assert first.returncode == 7
        output, error = second.communicate(timeout=5)
        assert output.strip() == 'entered', (output, error)
        assert second.returncode == 7
        with lock.open('r') as observer:
            fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('PASS two jobs serialized; exit 7 preserved; lock released')
    finally:
        for child in (first, second):
            if child is not None and child.poll() is None:
                child.kill(); child.wait()
`, fileURLToPath(new URL("../scripts/queue-heavy-suite.py", import.meta.url))], {
    env: process.env, encoding: "utf8", timeout: 10_000,
  });
  expect(result.error).toBeUndefined();
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("PASS two jobs serialized");
}, 15_000);
