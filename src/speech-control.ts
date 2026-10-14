import { timingSafeEqual, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, lstatSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseCommand, type SocketCommand, type SocketResponse } from "./socket-protocol";
import { getMcpSocketOverridePath } from "./paths";
import type { LongReadHandle } from "./tts";

export function speechSecretPath(): string {
  if (process.env.VOICELAYER_DAEMON_SECRET_PATH) return process.env.VOICELAYER_DAEMON_SECRET_PATH;
  // Existing Qwen3 token-file aliases are also honored by the CLI/daemon.
  const ttsSecret = process.env.VOICELAYER_TTS_DAEMON_SECRET_FILE || process.env.VOICELAYER_TTS_AUTH_TOKEN_FILE;
  if (ttsSecret) return ttsSecret;
  if (process.env.VOICELAYER_STATE_DIR) return join(process.env.VOICELAYER_STATE_DIR, "daemon.secret");
  const isolatedSocket = getMcpSocketOverridePath();
  return isolatedSocket ? `${isolatedSocket}.secret` : join(homedir(), ".voicelayer", "daemon.secret");
}
export function loadSpeechSecret(): string {
  const path = speechSecretPath();
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  try { writeFileSync(path, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  return readSpeechSecret(path);
}
/** Align with Qwen3's strict token policy, for both daemon and CLI reads. */
export function readSpeechSecret(path = speechSecretPath()): string {
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) throw new Error("Refusing daemon speech secret symlink");
  if (!stat.isFile() || (stat.mode & 0o777) !== 0o600) throw new Error("Daemon speech secret must be a regular 0600 file");
  const token = readFileSync(path, "utf8").trim();
  if (!token) throw new Error("Empty daemon speech secret");
  return token;
}

export type SpeechControl = (params: Record<string, unknown>) => Promise<Record<string, unknown>>;
export function createSpeechControl(token: string, handle: (
  command: SocketCommand, lifecycle?: (read: LongReadHandle) => void,
) => SocketResponse | void | Promise<SocketResponse>): SpeechControl {
  return async (params) => {
    const supplied = typeof params.token === "string" ? Buffer.from(params.token) : Buffer.alloc(0);
    const expected = Buffer.from(token);
    if (!expected.length || supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) throw new Error("Unauthorized speech control");
    if (params.wait !== undefined && typeof params.wait !== "boolean") throw new Error("Invalid wait option");
    const command = parseCommand(JSON.stringify(params));
    if (!command || (command.cmd !== "speak_text" && command.cmd !== "stop")) throw new Error("Invalid speech command");
    let read: LongReadHandle | undefined;
    const ack = await handle(command, (value) => { read = value; });
    if (!ack || ack.type !== "ack" || ack.outcome === "reject") throw new Error(ack && "reason" in ack ? ack.reason : "Speech command rejected");
    if (command.cmd === "stop") return { status: ack.outcome };
    if (!read) throw new Error("Speech lifecycle unavailable");
    const started = await read.started;
    if (started.error) throw new Error(started.error);
    if (params.wait) {
      const outcome = await read.completion;
      if (outcome.error) throw new Error(outcome.error);
    }
    return { id: read.id, status: params.wait ? "completed" : "started" };
  };
}
