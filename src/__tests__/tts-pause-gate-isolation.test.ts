import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TEST_TMP } from "./setup/test-tmp";

test("paused drain fixture preserves an inherited UNKNOWN gate", async () => {
  const root = mkdtempSync(join(TEST_TMP, "paused-gate-order-"));
  const fault = join(root, "fault.ts");
  writeFileSync(fault, `
    import { afterAll, expect } from 'bun:test';
    import { readFileSync } from 'node:fs';
    import { withUpdateGateLock, readUpdateGateFile } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate-storage.ts"))};
    import { withVoiceAdmission } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate-admission.ts"))};
    const shared = process.env.VOICELAYER_UPDATE_GATE_PATH;
    withUpdateGateLock(() => withVoiceAdmission(() => {}));
    expect(readUpdateGateFile()).toEqual({ kind: 'UNKNOWN' });
    const evidence = readFileSync(shared + '.voice-diag.json', 'utf8');
    afterAll(() => {
      expect(process.env.VOICELAYER_UPDATE_GATE_PATH).toBe(shared);
      expect(readUpdateGateFile()).toEqual({ kind: 'UNKNOWN' });
      expect(readFileSync(shared + '.voice-diag.json', 'utf8')).toBe(evidence);
      console.log('PAUSED_SHARED_GATE_RETAINED');
    });
  `);
  const child = Bun.spawn([process.execPath, "test", "--preload", fault,
    "src/__tests__/tts-pause.test.ts", "-t",
    "admitted paused playback restarts during drain without new admission"],
    { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 10_000 });
  const [stdout, stderr, exit] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  expect({ exit, stdout, stderr }).toMatchObject({ exit: 0 });
  expect(stderr).toContain("1 pass");
  expect(stdout).toContain("PAUSED_SHARED_GATE_RETAINED");
}, 15_000);
