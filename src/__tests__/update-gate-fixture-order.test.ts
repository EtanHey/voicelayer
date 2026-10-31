import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
test("exporter then cached importer restores gate/proof before voice consumer", async () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "order-"));
  const capture = join(root, "capture.ts"), consumer = join(root, "consumer.test.ts");
  writeFileSync(capture, `globalThis.__gateFixtureEnv = { gate: process.env.VOICELAYER_UPDATE_GATE_PATH, proof: process.env.VOICELAYER_TEST_INSTALL_PROOF };`);
  writeFileSync(consumer, `import {test,expect} from 'bun:test';
    import {withVoiceAdmission} from ${JSON.stringify(join(process.cwd(), "src/update-gate-admission.ts"))};
    test('ordered voice consumer', () => {
      expect(process.env.VOICELAYER_UPDATE_GATE_PATH).toBe(globalThis.__gateFixtureEnv.gate);
      expect(process.env.VOICELAYER_TEST_INSTALL_PROOF).toBe(globalThis.__gateFixtureEnv.proof);
      expect(withVoiceAdmission(() => 'voice admitted')).toBe('voice admitted');
    });`);
  const child = Bun.spawn([process.execPath, "test", "--preload", capture,
    "./src/__tests__/update-gate-installer.test.ts", "./src/__tests__/update-gate-installer-final.test.ts", consumer],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  const output = await new Response(child.stderr).text();
  await Bun.write(join(root, "ordered-output.log"), output);
  expect({ exit: await child.exited, output: output.slice(-1000) }).toMatchObject({ exit: 0 });
  expect(output).toMatch(/ 50 pass\n 0 fail/);
}, 60000);
