/** Exercise all live-STT gates with sentinel tools, never real STT. */
import { test, expect } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";

for (const value of [undefined, "0", "true"]) test(`real-STT gate: ${String(value)} plus long flag cannot probe or decode`, async () => {
  const root = testTmp("real-stt-opt-in", String(value)); mkdirSync(root, { recursive: true });
  const marker = join(root, "tool-invoked");
  for (const tool of ["which", "say", "sox", "whisper-cli", "whisper-cpp"]) {
    writeFileSync(join(root, tool), `#!/bin/sh\nprintf 'unexpected tool call\\n' >> "$ADAPTER_TEST_TOOL_MARKER"\nexit 1\n`, { mode: 0o700 });
  }
  const env = { ...process.env, PATH: root + ":" + process.env.PATH, QA_VOICE_GOLDEN_LONG: "1", ADAPTER_TEST_TOOL_MARKER: marker };
  if (value === undefined) delete env.QA_VOICE_GOLDEN_LIVE;
  else env.QA_VOICE_GOLDEN_LIVE = value;
  const modules = ["stt-golden-eval-live.test.ts", "stt-punctuation-golden.test.ts", "stt-smart-chunking-golden.test.ts", "rules-engine-number-audio.test.ts"];
  const proc = Bun.spawn([process.execPath, "test", ...modules.map(name => join(import.meta.dir, name))], { env, stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(code).toBe(0); expect(out + err).toContain("SKIPPING real STT");
  expect(out + err).toContain("10 skip"); expect(existsSync(marker)).toBe(false);
});
