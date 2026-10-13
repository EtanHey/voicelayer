import { describe, test, expect } from "bun:test";
import { parseSpeakArgs, runSpeakCli, requestSpeech } from "../cli/speak";
import { createMcpDaemon } from "../mcp-daemon";
import { createSpeechControl, speechSecretPath, loadSpeechSecret } from "../speech-control";
import { join } from "node:path";
import { writeFileSync, unlinkSync, mkdirSync, rmSync, statSync } from "node:fs";
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
  test("local fallback streams in an isolated child and waits on request", async () => {
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
