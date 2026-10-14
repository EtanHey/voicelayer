import { describe, test, expect } from "bun:test";
import { parseSpeakArgs, runSpeakCli, requestSpeech } from "../cli/speak";
import { createMcpDaemon } from "../mcp-daemon";
import { createSpeechControl, speechSecretPath, loadSpeechSecret } from "../speech-control";
import { join } from "node:path";
import { writeFileSync, unlinkSync, mkdirSync, rmSync, statSync, chmodSync, symlinkSync, readFileSync, existsSync } from "node:fs";
import { createConnection } from "node:net";
import { STATE_DIR } from "../paths";

const io = (stdin = "") => ({ readStdin: async () => stdin, readFile: async () => "# File", stderr: (_s: string) => {}, stdout: (_s: string) => {} });

describe("speak CLI", () => {
  test("literal, stdin and markdown defaults", async () => {
    expect(await parseSpeakArgs(["hello"], io())).toMatchObject({ text: "hello", profile: "auto", format: "plain", wait: false });
    expect(await parseSpeakArgs([], io("# Piped"))).toMatchObject({ text: "# Piped", format: "plain" });
    expect(await parseSpeakArgs(["-", "--markdown", "--profile", "long", "--wait"], io("# Piped"))).toMatchObject({ text: "# Piped", format: "markdown", profile: "long", wait: true });
    expect(await parseSpeakArgs(["--file", "read.MD"], io())).toMatchObject({ text: "# File", format: "markdown" });
    expect(await parseSpeakArgs(["--file", "read.txt"], io())).toMatchObject({ format: "plain" });
    expect(await parseSpeakArgs(["--stop"], io())).toMatchObject({ cmd: "stop" });
  });
  test("invalid and empty inputs fail", async () => {
    for (const args of [[], [""], ["--profile", "bad"], ["--file"], ["--oops"], ["--stop", "hello"], ["--file", "a", "hello"], ["hello", "world"]]) {
      await expect(parseSpeakArgs(args, io())).rejects.toThrow();
    }
  });
  test("fallback only on unavailable daemon; errors and stop are nonzero", async () => {
    let fallback = 0;
    const deps = { ...io(), request: async () => { throw Object.assign(new Error("down"), { code: "ENOENT" }); }, local: async () => { fallback++; } };
    expect(await runSpeakCli(["hello"], deps)).toBe(0);
    expect(fallback).toBe(1);
    expect(await runSpeakCli(["--stop"], deps)).toBe(1);
    expect(await runSpeakCli(["hello"], { ...deps, request: async () => { throw new Error("busy"); } })).toBe(1);
    expect(fallback).toBe(1);
    expect(await runSpeakCli(["hello"], { ...deps, local: async () => { throw new Error("synthesis failed"); } })).toBe(1);
    expect(await runSpeakCli(["--help"], deps)).toBe(0);
  });
  test("authenticated real socket routes speech and stop without MCP tools", async () => {
    const socketPath = join(STATE_DIR, "d.sock");
    const received: unknown[] = [];
    const control = createSpeechControl("test-token", async (command, lifecycle) => {
      received.push(command);
      if (command.cmd === "speak_text") lifecycle?.({ id: "read", started: Promise.resolve({}), completion: Promise.resolve({}), done: Promise.resolve() });
      return { type: "ack", command: command.cmd, outcome: "accept" };
    });
    const daemon = await createMcpDaemon({ socketPath, speechControl: control });
    try {
      await requestSpeech({ cmd: "speak_text", text: "x".repeat(5000), profile: "long", format: "markdown", wait: false }, { socketPath, token: "test-token" });
      await requestSpeech({ cmd: "stop" }, { socketPath, token: "test-token" });
      expect(received).toEqual([{ cmd: "speak_text", text: "x".repeat(5000), profile: "long", format: "markdown", source: "cli" }, { cmd: "stop" }]);
      await expect(requestSpeech({ cmd: "stop" }, { socketPath, token: "wrong" })).rejects.toThrow("Unauthorized");
      expect(received.length).toBe(2);
    } finally { daemon.stop(); }
  });
  test("shell entry reads piped stdin and file; errors exit nonzero", async () => {
    const socketPath = join(STATE_DIR, "shell.sock");
    const secretPath = join(STATE_DIR, "shell.secret");
    writeFileSync(secretPath, "shell-token", { mode: 0o600 });
    const received: any[] = [];
    const daemon = await createMcpDaemon({ socketPath, speechControl: createSpeechControl("shell-token", async (command, lifecycle) => {
      received.push(command);
      lifecycle?.({ id: "read", started: Promise.resolve({}), completion: Promise.resolve({}), done: Promise.resolve() });
      return { type: "ack", command: command.cmd as "speak_text", outcome: "accept" };
    }) });
    const file = join(STATE_DIR, "read.md"); writeFileSync(file, "# File read");
    const run = async (args: string[], stdin = "") => {
      const child = Bun.spawn(["bash", "src/cli/voicelayer.sh", "speak", ...args], { env: { ...process.env, VOICELAYER_MCP_SOCKET_PATH: socketPath, VOICELAYER_DAEMON_SECRET_PATH: secretPath }, stdin: new Blob([stdin]), stdout: "pipe", stderr: "pipe" });
      const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
      return { code, stderr };
    };
    try {
      expect((await run([], "Piped text")).code).toBe(0);
      expect((await run(["--file", file, "--wait"])).code).toBe(0);
      expect(received).toMatchObject([{ text: "Piped text", format: "plain" }, { text: "# File read", format: "markdown" }]);
      expect((await run(["--file", `${file}.missing`])).code).toBe(1);
      expect((await run(["--profile", "bad"])).code).toBe(1);
    } finally { daemon.stop(); unlinkSync(secretPath); unlinkSync(file); }
  });
  test("local fallback runs in the foreground until completion", async () => {
    const dir = join(STATE_DIR, "fallback"); mkdirSync(dir, { recursive: true });
    const scripts: Record<string, string> = {
      python3: "#!/bin/bash\nfor arg in \"$@\"; do case \"$arg\" in --write-media=*) printf audio > \"${arg#*=}\" ;; --write-metadata=*) printf '{ \"text\": \"hello\", \"offset\": 0, \"duration\": 5000000 }' > \"${arg#*=}\" ;; esac; done\n",
      ffprobe: '#!/bin/bash\nprintf "1\\n"\n',
      ffmpeg: '#!/bin/bash\nlast="${@: -1}"\nif [[ "$last" == "pipe:1" ]]; then printf "00000000"; else printf audio > "$last"; fi\n',
      afplay: '#!/bin/bash\nsleep 0.1\n',
    };
    for (const [name, source] of Object.entries(scripts)) writeFileSync(join(dir, name), source, { mode: 0o700 });
    try {
      const child = Bun.spawn([process.execPath, "src/cli/speak.ts", "hello", "--wait"], {
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, VOICELAYER_MCP_SOCKET_PATH: join(dir, "missing.sock"), QA_VOICE_TTS_VOICE: "en-US-JennyNeural" }, stdout: "pipe", stderr: "pipe",
      });
      const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
      expect(stderr).toContain("daemon unavailable; speaking locally");
      expect(code).toBe(0);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test("secret isolation follows canonical and legacy socket overrides", () => {
    const old = { ...process.env };
    try {
      delete process.env.VOICELAYER_STATE_DIR; delete process.env.VOICELAYER_DAEMON_SECRET_PATH;
      process.env.VOICELAYER_MCP_SOCKET_PATH = "/tmp/d-isolated.sock";
      process.env.QA_VOICE_MCP_SOCKET_PATH = "/tmp/d-legacy.sock";
      expect(speechSecretPath()).toBe("/tmp/d-isolated.sock.secret");
      delete process.env.VOICELAYER_MCP_SOCKET_PATH;
      expect(speechSecretPath()).toBe("/tmp/d-legacy.sock.secret");
      process.env.VOICELAYER_DAEMON_SECRET_PATH = join(STATE_DIR, "new.secret");
      const token = loadSpeechSecret();
      expect(loadSpeechSecret()).toBe(token);
      expect(statSync(speechSecretPath()).mode & 0o777).toBe(0o600);
      unlinkSync(speechSecretPath());
    } finally { process.env = old; }
  });
  test("default awaits start, wait awaits completion; failed start propagates", async () => {
    let finish!: (value: {}) => void;
    const completion = new Promise<{}>(r => { finish = r; });
    const control = createSpeechControl("t", async (_command, lifecycle) => {
      lifecycle?.({ id: "read", started: Promise.resolve({}), completion, done: Promise.resolve() });
      return { type: "ack", command: "speak_text", outcome: "accept" };
    });
    expect(await control({ token: "t", cmd: "speak_text", text: "hi" })).toMatchObject({ status: "started" });
    let ended = false;
    const waiting = control({ token: "t", cmd: "speak_text", text: "hi", wait: true }).then(() => { ended = true; });
    await Bun.sleep(10); expect(ended).toBe(false); finish({}); await waiting;
    const failed = createSpeechControl("t", async (_command, lifecycle) => {
      lifecycle?.({ id: "read", started: Promise.resolve({ error: "synthesis failed" }), completion: Promise.resolve({}), done: Promise.resolve() });
      return { type: "ack", command: "speak_text", outcome: "accept" };
    });
    await expect(failed({ token: "t", cmd: "speak_text", text: "hi" })).rejects.toThrow("synthesis failed");
  });
});


async function until(check: () => boolean) {
  const deadline = Date.now() + 3000;
  while (!check()) { if (Date.now() > deadline) throw new Error("Fixture did not advance"); await Bun.sleep(10); }
}
function alive(pid: number): boolean { try { process.kill(pid, 0); return true; } catch { return false; } }
function rpc(path: string, method: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path); let buffer = "";
    socket.on("error", reject);
    socket.on("connect", () => socket.write(JSON.stringify({ jsonrpc: "2.0", id: 4, method }) + "\n"));
    socket.on("data", data => { buffer += data.toString(); if (buffer.includes("\n")) { socket.destroy(); resolve(JSON.parse(buffer.split("\n")[0])); } });
  });
}

describe("speak CLI review regressions", () => {
  test("stop when daemon is down has a useful message for both connection errors", async () => {
    for (const code of ["ENOENT", "ECONNREFUSED"]) {
      let stderr = "";
      expect(await runSpeakCli(["--stop"], { ...io(), stderr: message => { stderr += message; }, request: async () => { throw Object.assign(new Error(`connect ${code}`), { code }); }, local: async () => { throw new Error("must not fallback"); } })).toBe(1);
      expect(stderr).toContain("VoiceLayer daemon isn't running; nothing to stop");
      expect(stderr).not.toContain(`connect ${code}`);
    }
  });
  for (const kind of ["symlink", "world-readable", "empty"]) test(`secret rejects ${kind}`, () => {
    const old = { ...process.env }, file = join(STATE_DIR, "r1.secret"), link = `${file}.link`;
    try {
      writeFileSync(file, kind === "empty" ? "   " : "fixture", { mode: 0o600 });
      if (kind === "world-readable") chmodSync(file, 0o644);
      if (kind === "symlink") symlinkSync(file, link);
      process.env.VOICELAYER_DAEMON_SECRET_PATH = kind === "symlink" ? link : file;
      expect(() => loadSpeechSecret()).toThrow(kind === "world-readable" ? "0600" : kind === "symlink" ? "symlink" : "Empty");
    } finally { process.env = old; for (const path of [link, file]) try { unlinkSync(path); } catch {} }
  });
  test("secret recognizes the existing TTS path aliases", () => {
    const old = { ...process.env };
    try {
      delete process.env.VOICELAYER_DAEMON_SECRET_PATH;
      process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE = "/isolated/tts.secret";
      process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE = "/isolated/alias.secret";
      expect(speechSecretPath()).toBe("/isolated/tts.secret");
      delete process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE;
      expect(speechSecretPath()).toBe("/isolated/alias.secret");
    } finally { process.env = old; }
  });
  test("wait unblocks after a concurrent stop; tools remain the canonical two", async () => {
    const socketPath = join(STATE_DIR, "r1.sock");
    let finish!: (value: {}) => void;
    const completion = new Promise<{}>(resolve => { finish = resolve; });
    let speaking = false, ended = false;
    const daemon = await createMcpDaemon({ socketPath, speechControl: createSpeechControl("token", async (command, lifecycle) => {
      if (command.cmd === "speak_text") { speaking = true; lifecycle?.({ id: "r1", started: Promise.resolve({}), completion, done: completion.then(() => {}) }); }
      else { finish({}); await completion; }
      return { type: "ack", command: command.cmd as "speak_text" | "stop", outcome: "accept" };
    }) });
    try {
      const waiting = requestSpeech({ cmd: "speak_text", text: "read", profile: "auto", format: "plain", wait: true }, { socketPath, token: "token" }).then(() => { ended = true; });
      await until(() => speaking); expect(ended).toBe(false);
      await requestSpeech({ cmd: "stop" }, { socketPath, token: "token" }); await waiting;
      expect(ended).toBe(true);
      expect((await rpc(socketPath, "tools/list")).result.tools.map((tool: any) => tool.name)).toEqual(["voice_speak", "voice_ask"]);
    } finally { daemon.stop(); }
  });
  for (const signal of ["SIGINT", "SIGTERM"] as const) for (const phase of ["synth", "player"]) test(`${signal} reaps foreground fallback during ${phase}`, async () => {
    const dir = join(STATE_DIR, `r1-${phase}`); mkdirSync(dir, { recursive: true });
    const fixture = `#!${process.execPath}
import { writeFileSync } from "node:fs";
const dir = process.env.R1_DIR;
const kind = process.argv[1].endsWith("afplay") ? "player" : "synth";
writeFileSync(dir + "/" + kind + ".pid", String(process.pid));
writeFileSync(dir + "/owner.pid", String(process.ppid));
if (kind === "synth" && process.env.R1_PHASE === "player") {
 for (const arg of process.argv) { if (arg.startsWith("--write-media=")) writeFileSync(arg.slice(14), "audio"); if (arg.startsWith("--write-metadata=")) writeFileSync(arg.slice(17), '{"text":"hello","offset":0,"duration":5000000}'); }
 process.exit(0);
}
process.on("SIGTERM", () => { writeFileSync(dir + "/" + kind + ".stopped", "yes"); process.exit(0); });
writeFileSync(dir + "/" + kind + ".ready", "yes");
setInterval(() => {}, 1000);
`;
    for (const name of ["python3", "afplay"]) writeFileSync(join(dir, name), fixture, { mode: 0o700 });
    writeFileSync(join(dir, "ffprobe"), '#!/bin/bash\nprintf "1\\n"\n', { mode: 0o700 });
    writeFileSync(join(dir, "ffmpeg"), '#!/bin/bash\nlast="${@: -1}"\nif [[ "$last" == "pipe:1" ]]; then printf "00000000"; else printf audio > "$last"; fi\n', { mode: 0o700 });
    const child = Bun.spawn([process.execPath, "src/cli/speak.ts", "hello"], { env: { ...process.env, R1_DIR: dir, R1_PHASE: phase, PATH: `${dir}:${process.env.PATH}`, VOICELAYER_TMP_ROOT: dir, VOICELAYER_STATE_DIR: join(dir, "state"), VOICELAYER_MCP_SOCKET_PATH: join(dir, "missing.sock"), QA_VOICE_TTS_VOICE: "en-US-JennyNeural" }, stdout: "ignore", stderr: Bun.file(join(dir, "stderr")) });
    const pids: number[] = [];
    try {
      await until(() => existsSync(join(dir, `${phase}.ready`)));
      pids.push(Number(readFileSync(join(dir, `${phase}.pid`), "utf8")), Number(readFileSync(join(dir, "owner.pid"), "utf8")));
      child.kill(signal);
      expect(await child.exited).not.toBe(0);
      await Bun.sleep(100);
      expect(pids.every(pid => !alive(pid))).toBe(true);
      expect(existsSync(join(dir, `${phase}.stopped`))).toBe(true);
    } finally {
      child.kill("SIGKILL");
      for (const pid of pids) if (alive(pid)) try { process.kill(pid, "SIGKILL"); } catch {}
      await child.exited; await Bun.sleep(50); rmSync(dir, { recursive: true, force: true });
    }
  });
});
