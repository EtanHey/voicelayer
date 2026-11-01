import { test, expect, spyOn } from "bun:test";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { WhisperCppBackend, WhisperCliError } from "../stt";

test("owned one-shot fallback abort waits for exit and retains raw partial provider output", async () => {
  const root = testTmp("parakeet-cli-stop"); mkdirSync(root, { recursive: true });
  const cli = root + "/cli", marker = root + "/started.json";
  writeFileSync(cli, `#!${process.execPath}\nimport { writeFileSync, writeSync } from 'fs';\nwriteSync(1,'raw partial provider text');\nwriteFileSync(${JSON.stringify(marker)},JSON.stringify({pid:process.pid,args:process.argv.slice(2)}));\nsetInterval(()=>{},1000);\n`, { mode: 0o700 });
  const controller = new AbortController();
  const backend = new WhisperCppBackend({ signal: controller.signal, noVocabularyPrompt: true });
  Object.assign(backend, { binaryPath: cli, modelPath: root + "/fake-model" });
  // This fixture must not resolve or probe the host's brew/engine binaries.
  const probe = spyOn(Bun, "spawnSync").mockImplementation(() => ({ exitCode: 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }) as ReturnType<typeof Bun.spawnSync>);
  const result = backend.transcribe(root + "/input.wav", { language: "he" }).then(value => ({ value, error: null }), error => ({ value: null, error }));
  try {
    for (let n = 0; n < 200 && !existsSync(marker); n++) await Bun.sleep(5);
    expect(existsSync(marker)).toBe(true);
    const invocation = JSON.parse(readFileSync(marker, "utf8"));
    expect(invocation.args).not.toContain("--prompt");
    expect(invocation.args[invocation.args.indexOf("-l") + 1]).toBe("he");
    controller.abort();
    const settled = await result;
    expect(settled.value).toBeNull(); expect(settled.error).toBeInstanceOf(WhisperCliError);
    expect(settled.error.attempt.stdout).toBe("raw partial provider text");
    expect(settled.error.attempt.exitCode).not.toBe(0);
  } finally { controller.abort(); await result; probe.mockRestore(); }
});
