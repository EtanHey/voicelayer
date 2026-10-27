import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const pythonDependencies = Bun.spawnSync({
  cmd: ["python3", "-c", "import fastapi, uvicorn"],
  env: process.env,
  stdout: "ignore",
  stderr: "pipe",
});
const hasPythonDependencies = pythonDependencies.exitCode === 0;
if (!hasPythonDependencies) {
  console.warn(
    "SKIP qwen3-cancel: python3 cannot import fastapi, uvicorn. " +
    "Install tests/requirements-tts-daemon.txt for this integration test.\n" +
    pythonDependencies.stderr.toString(),
  );
}

test.skipIf(!hasPythonDependencies)("aborting clone synthesis releases the Python worker for the next clone", async () => {
  const root = mkdtempSync(join(tmpdir(), "qwen-cancel-"));
  const child = Bun.spawn({
    cmd: [process.execPath, "-e", `
      import { existsSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
      import { join } from "node:path";
      const root = process.env.QWEN_CANCEL_TEST_ROOT;
      const daemon = Bun.spawn({
        cmd: ["python3", "tests/fixtures/qwen_cancel_daemon.py", root],
        env: process.env, stdout: "ignore", stderr: "inherit",
      });
      const waitFor = async (predicate) => {
        const deadline = Date.now() + 5000;
        while (!await predicate()) {
          if (Date.now() >= deadline) throw new Error("stub daemon timed out");
          await Bun.sleep(10);
        }
      };
      try {
        await waitFor(() => existsSync(join(root, "ready.json")));
        const { port } = JSON.parse(readFileSync(join(root, "ready.json"), "utf8"));
        const base = "http://127.0.0.1:" + port;
        const token = readFileSync(join(root, "secret"), "utf8").trim();
        const realFetch = globalThis.fetch;
        globalThis.fetch = (url, init) => realFetch(base + new URL(url).pathname, init);
        await waitFor(async () => (await fetch(base + "/health", {
          headers: { Authorization: "Bearer " + token },
        }).catch(() => null))?.ok);
        const voice = join(root, ".voicelayer/voices/fixture");
        mkdirSync(voice, { recursive: true });
        writeFileSync(join(voice, "profile.yaml"), [
          "name: fixture", "engine: qwen3-tts",
          "reference_clip: " + join(root, "voices/clip.wav"),
          "reference_text: fixture",
        ].join("\\n"));
        process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE = join(root, "secret");
        const { synthesizeCloned } = await import("./src/tts/qwen3.ts");
        const controller = new AbortController();
        const first = synthesizeCloned("slow", "fixture", controller.signal)
          .then(() => "unexpected success", error => error.name);
        await waitFor(() => existsSync(join(root, "steps-slow")));
        const started = performance.now();
        controller.abort();
        const aborted = await first;
        const next = await synthesizeCloned("next", "fixture");
        console.log(JSON.stringify({ aborted, elapsed: performance.now() - started,
          next: next?.toString(), closed: existsSync(join(root, "closed-slow")) }));
      } finally {
        daemon.kill("SIGTERM");
        await Promise.race([daemon.exited, Bun.sleep(1000)]);
        if (daemon.exitCode === null) daemon.kill("SIGKILL");
        await daemon.exited;
      }
    `],
    env: { ...process.env, HOME: root, QWEN_CANCEL_TEST_ROOT: root },
    stdout: "pipe",
    stderr: "pipe",
  });
  try {
    const [output, errors, exitCode] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    expect(errors).not.toContain("Traceback");
    expect({ exitCode, errors }).toMatchObject({ exitCode: 0 });
    const result = JSON.parse(output);
    expect(result.aborted).toBe("AbortError");
    expect(result.next).toBe("stub-mp3");
    expect(result.closed).toBe(true);
    expect(result.elapsed).toBeLessThan(1000);
  } finally {
    child.kill();
    await child.exited;
    rmSync(root, { recursive: true, force: true });
  }
}, 20000);
