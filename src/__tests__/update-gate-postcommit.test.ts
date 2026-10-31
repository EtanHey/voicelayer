import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, writeFileSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { initializeVoiceGate } from "../update-gate-admission";
const saved = { ...process.env };
afterEach(() => { for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF"]) process.env[key] = saved[key]; });
test("R2: G1 holder right after durable COMMIT", async () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "rvc-")), gate = join(root, "gate");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  await initializeVoiceGate();
  const bin = join(root, "bin"), log = join(root, "calls"); mkdirSync(bin); writeFileSync(log, "");
  writeFileSync(join(bin, "brew"), '#!/bin/bash\necho install >> "$CALL_LOG"\n', { mode: 0o755 });
  const proof = join(root, "proof.json"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  const runner = join(root, "run.ts");
  writeFileSync(runner, `import { runGatedInstall } from ${JSON.stringify(join(process.cwd(), "src/update-gate-installer.ts"))};
    import { mkdirSync, rmdirSync } from "node:fs"; import { retryInstallerAcquisition } from "${process.cwd()}/src/update-gate-installer-participant.ts";
    let n = 0;
    const lock = process.env.VOICELAYER_UPDATE_GATE_PATH + ".lock";
    try { process.exitCode = await runGatedInstall(["brew", "install"], {
      async withAcquisitionProof(read) { const r = await retryInstallerAcquisition(read); if (r && r.kind === "APPLIED" && r.state?.kind === "COMMITTED") { mkdirSync(lock); setTimeout(() => rmdirSync(lock), 700); } return r; },
      async refresh(lease) {
        const ack = { lease, activeOperations: 0, openArchives: 0 }; return { phase: "idle", ready: true, native: ack, daemon: ack }; },
      verify() { return true; },
      async quit() {},
    }); } catch (e) { console.error("THREW " + String(e)); process.exitCode = 1; }
    await Bun.sleep(800);`);
  const child = Bun.spawn([process.execPath, runner], { env: { ...process.env, CALL_LOG: log, PATH: `${bin}:${process.env.PATH}`,
    VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) }, stdout: "pipe", stderr: "pipe", timeout: 8000 });
  const exit = await child.exited, err = await new Response(child.stderr).text();
  const state = JSON.parse(readFileSync(gate, "utf8"));
  expect({ exit, state: state.kind, install: readFileSync(log, "utf8").trim(), err }).toMatchObject({ exit: 0, state: "COMMITTED", install: "install" });
  expect(readdirSync(root).filter(x => x.includes("recovery"))).toEqual([]);
});
