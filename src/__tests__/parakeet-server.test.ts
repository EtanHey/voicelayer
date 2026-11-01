import { describe, test, expect, beforeAll, afterEach } from "bun:test";
import { mkdirSync, writeFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { ParakeetServer, ParakeetServiceError, parakeetCommand } from "../parakeet-server";

describe("private resident Parakeet lifecycle (protocol-only child)", () => {
  const fixture = testTmp("parakeet-pipes", "child.mjs");
  const servers: ParakeetServer[] = [];
  beforeAll(() => {
    mkdirSync(testTmp("parakeet-pipes"), { recursive: true });
    writeFileSync(fixture, `import { createInterface } from 'node:readline';
const rl=createInterface({input:process.stdin});
for await (const line of rl) {
 const r=JSON.parse(line),p=r.audio_path; let out={id:r.id,ok:true};
 if(r.op==='health'){
  out={...out,ready:true,protocol:1,pid:process.pid};
  if(process.argv[2]==='startup-cleanup'){
   Bun.spawn([process.execPath,'-e','await Bun.sleep(350)'],{env:process.env,stdout:'inherit',stderr:'inherit'});out.ready=false;
  }
 }
 else {
  if(p==='crash')process.exit(9);
  if(p==='partial'){process.stdout.write('{');process.exit(0);}
  if(p==='cleanup-timeout'){
   Bun.spawn([process.execPath,'-e','await Bun.sleep(350)'],{env:process.env,stdout:'inherit',stderr:'inherit'});
   process.stdout.write('invalid-json\\n');continue;
  }
  if(p==='invalid-utf8'){process.stdout.write(Buffer.from([255,254]));process.exit(0);}
  if(p==='partial-timeout'){process.stdout.write('{"text":');continue;}
  if(p==='timeout')continue;
  if(p==='idle-exit')setTimeout(()=>process.exit(7),30);
  if(p==='delay')await new Promise(r=>setTimeout(r,80));
  out={...out,text:'A complete response.',complete:true,input_frames:16000,covered_frames:16000,sample_rate:16000,last_token_end_s:1,inference_s:0.01,language:null};
  if(p==='empty')out.text='';
  if(p==='wrong-id')out.id++;
  if(p==='bad-frames')out.covered_frames=2;
  if(p==='provider-error')out={id:r.id,ok:false,code:'RuntimeError'};
  if(p==='returned-partial')out={id:r.id,ok:false,code:'ReturnedDecodeError',status:'PARTIAL',fatal:false,attempt:{text:'returned partial words',complete:false,covered_frames:10,input_frames:16000}};
 }
 const encoded=JSON.stringify(out)+'\\n';process.stdout.write(p==='duplicate'?encoded+encoded:encoded);
}`);
  });
  afterEach(async () => { for (const server of servers.splice(0)) await server.shutdown(); });
  function make(options: Partial<ConstructorParameters<typeof ParakeetServer>[0]> = {}) {
    const server = new ParakeetServer({ command: [process.execPath, fixture], startupMs: 3000, requestMs: 500, stopMs: 1000, idleSeconds: () => 600, isBusy: () => false, ...options }); servers.push(server); return server;
  }
  test("not configured never downloads or pretends available", () => { expect(parakeetCommand({})).toBeNull(); });
  test("health alone does not launch/load a model", async () => { expect(await make().health()).toBe(false); });
  test("persistent child serves empty then success without restarting serve", async () => {
    const s = make(); await s.start(); expect(await s.health()).toBe(true);
    expect((await s.transcribe("empty")).text).toBe(""); expect((await s.transcribe("normal")).text).toBe("A complete response."); expect(await s.health()).toBe(true);
  });
  test("concurrent requests preserve command identities", async () => {
    const s = make(); const rs = await Promise.all([s.transcribe("delay"), s.transcribe("normal"), s.transcribe("normal")]); expect(rs.length).toBe(3);
  });
  test.each(["crash", "partial", "wrong-id", "bad-frames", "provider-error"])("%s destroys owned service; a later request can start cleanly", async bad => {
    const s = make(); await expect(s.transcribe(bad)).rejects.toThrow(); expect(await s.health()).toBe(false);
    expect((await s.transcribe("normal")).complete).toBe(true);
  });
  test("timeout stops before a new request starts", async () => {
    const s = make({ requestMs: 30 }); await s.start(); await expect(s.transcribe("timeout")).rejects.toThrow("timeout"); expect(await s.health()).toBe(false); expect((await s.transcribe("normal")).complete).toBe(true);
  });
  test.each(["invalid-utf8", "partial-timeout"])("%s retains protocol evidence and stops before replacement", async bad => {
    const s = make({ requestMs: 50 }); await s.start();
    let caught: unknown;
    try { await s.transcribe(bad); } catch (error) { caught = error; }
    expect(caught).toBeInstanceOf(ParakeetServiceError);
    expect(["INVALID", "TIMEOUT"]).toContain((caught as ParakeetServiceError).status);
    expect((caught as ParakeetServiceError).attempt).toBeDefined();
    expect((caught as ParakeetServiceError).attempt).toHaveProperty("raw_stdout_base64");
    expect(s.pid).toBeNull(); expect((await s.transcribe("normal")).complete).toBe(true);
  });
  test("unsolicited duplicate never remains a reusable service", async () => {
    const s = make(); await s.start(); const firstPid = s.pid;
    // A conforming first line can settle before a later OS pipe chunk arrives.
    // The late unsolicited line must poison that child, not a successor's ID.
    try { await s.transcribe("duplicate"); } catch (error) { expect(error).toBeInstanceOf(ParakeetServiceError); }
    await Bun.sleep(20); expect(await s.health()).toBe(false);
    expect((await s.transcribe("normal")).complete).toBe(true); expect(s.pid).not.toBe(firstPid);
  });
  test("cleanup timeout preserves the primary provider bytes and keeps the owned barrier", async () => {
    const s = make({ stopMs: 20 }); await s.start();
    let caught: unknown;
    try { await s.transcribe("cleanup-timeout"); } catch (error) { caught = error; }
    try {
      expect(caught).toBeInstanceOf(ParakeetServiceError);
      expect((caught as ParakeetServiceError).attempt).toHaveProperty("raw_stdout_base64");
      expect((caught as ParakeetServiceError & { cleanupFailure?: unknown }).cleanupFailure).toBeDefined();
      expect((s as unknown as { child: unknown }).child).not.toBeNull();
      await expect(s.unload()).rejects.toThrow("streams did not close");
    } finally { await Bun.sleep(450); await s.shutdown(); }
  });
  test("worker partial envelopes retain returned words without qualifying native success", async () => {
    const s = make(); let caught: unknown;
    try { await s.transcribe("returned-partial"); } catch (error) { caught = error; }
    expect(caught).toBeInstanceOf(ParakeetServiceError);
    expect((caught as ParakeetServiceError).status).toBe("PARTIAL");
    expect((caught as ParakeetServiceError).attempt).toMatchObject({ attempt: { text: "returned partial words", complete: false, covered_frames: 10 } });
    expect(s.pid).toBeNull();
  });
  test("failed startup health and cleanup preserve the actual health receipt", async () => {
    const s = make({ command: [process.execPath, fixture, "startup-cleanup"], stopMs: 20 }); let caught: unknown;
    try { await s.start(); } catch (error) { caught = error; }
    try {
      expect(caught).toBeInstanceOf(ParakeetServiceError);
      expect((caught as ParakeetServiceError).attempt).toMatchObject({ ready: false, protocol: 1 });
      expect((caught as ParakeetServiceError).cleanupFailure).toBeDefined();
    } finally { await Bun.sleep(450); await s.shutdown(); }
  });
  test("owned restart and unload are usable without permanent shutdown", async () => {
    const s = make(); await s.start(); await s.restart(); expect(await s.health()).toBe(true); await s.unload(); expect(await s.health()).toBe(false); await s.start();
  });
  test("shutdown rejects later operations and is idempotent", async () => {
    const s = make(); await s.start(); await s.shutdown(); await s.shutdown(); await expect(s.transcribe("normal")).rejects.toThrow("shut down");
  });
  test("idle timer unloads model after use", async () => {
    const s = make({ idleSeconds: () => 0.04 }); await s.start(); await Bun.sleep(110); expect(await s.health()).toBe(false);
  });
  test("idle timer cannot unload an active request", async () => {
    const s = make({ idleSeconds: () => 0.02 }); expect((await s.transcribe("delay")).complete).toBe(true);
  });
  test("health checks do not reset the inference idle timer", async () => {
    const s = make({ idleSeconds: () => 0.08 }); await s.start();
    for (let n = 0; n < 4; n++) { await Bun.sleep(30); await s.health(); }
    expect(s.pid).toBeNull();
  });
  test("an unrelated CLI cannot start a second configured resident", async () => {
    const s = new ParakeetServer(); servers.push(s);
    expect(s.isAvailable()).toBe(false);
    await expect(s.start()).rejects.toThrow("VoiceBar MCP daemon"); expect(s.pid).toBeNull();
  });
  test("failed spawn never publishes an owned child or ready state", async () => {
    const s = make({ command: [testTmp("no-such-parakeet-python")] });
    await expect(s.start()).rejects.toThrow(); expect(s.pid).toBeNull(); expect(await s.health()).toBe(false);
  });
  test("idle unexpected exit publishes error without a status probe; intentional stop does not", async () => {
    const states: string[]=[]; const s=make({onState:phase=>{states.push(phase);}});
    await s.transcribe("idle-exit");expect(states.at(-1)).toBe("ready");await Bun.sleep(80);expect(states.at(-1)).toBe("error");
    const t=make({onState:phase=>{states.push("intentional-"+phase);}});await t.start();await t.unload();expect(states.at(-1)).toBe("intentional-sleeping");expect(states).not.toContain("intentional-error");
  });
  test("busy capture delays unload until it releases", async () => {
    let busy = true; const s = make({ idleSeconds: () => 0.04, isBusy: () => busy }); await s.start(); await Bun.sleep(90); expect(await s.health()).toBe(true); busy = false; await Bun.sleep(130); expect(await s.health()).toBe(false);
  });
});
