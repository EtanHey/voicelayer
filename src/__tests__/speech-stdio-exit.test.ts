import { expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

test("stdio SIGTERM flushes a completed record before process exit", async () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const moduleUrl = (name: string) => new URL(`../${name}.ts`, import.meta.url).href;
  const script = `
    import { spyOn } from "bun:test";
    const stt = await import(${JSON.stringify(moduleUrl("stt"))});
    spyOn(stt, "getBackend").mockResolvedValue({});
    const socket = await import(${JSON.stringify(moduleUrl("socket-client"))});
    spyOn(socket, "connectToBar").mockImplementation(() => {});
    await import(${JSON.stringify(moduleUrl("mcp-server"))});
    const { beginSpeechArchive } = await import(${JSON.stringify(moduleUrl("speech-archive-live"))});
    const archive = beginSpeechArchive("stdio shutdown fixture");
    await archive.settled();
    console.log(archive.context.path);
    archive.move("playing"); archive.finish("completed", "PLAYBACK_COMPLETED");
    process.emit("SIGTERM");
  `;
  const child = Bun.spawn([process.execPath, "-e", script], { env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 4000);
  try {
    const output = await new Response(child.stdout).text();
    const errors = await new Response(child.stderr).text();
    expect(await child.exited).toBe(0);
    expect(errors).not.toContain("Fatal");
    const path = output.trim();
    expect(path).toStartWith(process.env.VOICELAYER_TEST_RUN_ROOT!);
    expect(JSON.parse(readFileSync(join(path, "metadata.json"), "utf8")).speech.state).toBe("completed");
  } finally { clearTimeout(timeout); child.kill(); }
});
