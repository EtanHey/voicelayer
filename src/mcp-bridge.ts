#!/usr/bin/env bun
import { createConnection, type Socket } from "node:net";
import { StringDecoder } from "node:string_decoder";
import { z } from "zod";
import { getMcpSocketPath } from "./paths";

const envelope = z.looseObject({
  jsonrpc: z.literal("2.0"),
  id: z.union([z.string(), z.number(), z.null()]).optional(),
  method: z.string().optional(),
});
type Frame = { wire: string; message: z.infer<typeof envelope> };
const MAX_BYTES = 1024 * 1024;
const MAX_REQUESTS = 128;
const parse = (wire: string): Frame => ({ wire, message: envelope.parse(JSON.parse(wire)) });

function frameReader(onFrame: (frame: Frame) => void) {
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  return (data: Buffer) => {
    buffer += decoder.write(data);
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const wire = buffer.slice(0, newline + 1); buffer = buffer.slice(newline + 1);
      if (Buffer.byteLength(wire) > MAX_BYTES) throw new Error("Frame exceeds 1 MiB");
      if (wire.trim()) onFrame(parse(wire));
    }
    if (Buffer.byteLength(buffer) > MAX_BYTES) throw new Error("Frame exceeds 1 MiB");
  };
}

export function runBridge() {
  const path = getMcpSocketPath();
  let socket: Socket | undefined;
  let state: "offline" | "replaying" | "ready" = "offline";
  let initialize: Frame | undefined;
  let initialized: Frame | undefined;
  let queue: Frame[] = [];
  let queuedBytes = 0;
  const pending = new Map<string | number | null, Frame>();
  let delay = 100;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let handshake: ReturnType<typeof setTimeout> | undefined;
  let drain: ReturnType<typeof setTimeout> | undefined;
  let ending = false;
  let closed = false;
  const output = (wire: string) => {
    if (!process.stdout.write(wire)) { socket?.pause(); process.stdin.pause(); }
  };
  const error = (frame: Frame, code: number, message: string) => {
    if (frame.message.method && frame.message.id !== undefined)
      output(JSON.stringify({ jsonrpc: "2.0", id: frame.message.id, error: { code, message } }) + "\n");
  };
  const stop = () => {
    closed = true; clearTimeout(retry); clearTimeout(handshake); clearTimeout(drain); socket?.destroy(); process.stdin.destroy();
  };
  const finish = () => { if (ending && !queue.length && !pending.size && state !== "replaying") stop(); };
  const disconnect = () => {
    if (closed || state === "offline" && retry) return;
    state = "offline"; clearTimeout(handshake); socket?.destroy(); socket = undefined;
    for (const frame of pending.values()) error(frame, -32000, "VoiceLayer disconnected; execution may have occurred. Request will not be retried.");
    pending.clear();
    process.stderr.write(JSON.stringify({ event: "mcp_bridge_reconnect", delayMs: delay }) + "\n");
    retry = setTimeout(connect, delay); delay = Math.min(delay * 2, 2000);
    finish();
  };
  const send = (frame: Frame) => {
    const { id, method } = frame.message;
    if (id !== undefined && method) {
      if (pending.has(id) || pending.size >= MAX_REQUESTS) {
        error(frame, -32001, "Too many outstanding requests or duplicate request ID"); return;
      }
      pending.set(id, frame);
    }
    if (method === "initialize") initialize = frame;
    if (method === "notifications/initialized") initialized = frame;
    socket?.write(frame.wire);
  };
  const flush = () => {
    while (state === "ready" && queue.length) {
      const frame = queue[0];
      if ((socket?.writableLength ?? MAX_BYTES) + Buffer.byteLength(frame.wire) > MAX_BYTES) return;
      queue.shift(); queuedBytes -= Buffer.byteLength(frame.wire); send(frame);
    }
    finish();
  };
  const receive = (frame: Frame) => {
    const { id, method } = frame.message;
    if (state === "replaying") {
      if (!method && id === initialize?.message.id) {
        if ("error" in frame.message) { disconnect(); return; }
        clearTimeout(handshake);
        const queuedInitialized = queue.find(frame => frame.message.method === "notifications/initialized");
        if (queuedInitialized) {
          queue = queue.filter(frame => frame !== queuedInitialized);
          queuedBytes -= Buffer.byteLength(queuedInitialized.wire);
        }
        initialized = queuedInitialized ?? initialized;
        socket?.write(initialized?.wire ?? '{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
        state = "ready"; delay = 100; flush();
      }
      return;
    }
    if (!method && id !== undefined) {
      if (!pending.delete(id)) return;
    }
    output(frame.wire);
    finish();
  };
  function connect() {
    retry = undefined;
    if (closed) return;
    const current = createConnection(path); socket = current;
    const read = frameReader(frame => { if (socket === current) receive(frame); });
    current.on("connect", () => {
      if (initialize) {
        state = "replaying"; current.write(initialize.wire);
        handshake = setTimeout(disconnect, 5000);
      } else { state = "ready"; delay = 100; flush(); }
    });
    current.on("data", data => {
      if (socket !== current) return;
      try { read(typeof data === "string" ? Buffer.from(data) : data); } catch { disconnect(); }
    });
    current.on("error", () => { if (socket === current) disconnect(); });
    current.on("close", () => { if (socket === current) disconnect(); });
    current.on("drain", () => { if (socket === current) flush(); });
  }
  const input = frameReader(frame => {
    if (state === "ready" && !queue.length && (socket?.writableLength ?? MAX_BYTES) + Buffer.byteLength(frame.wire) <= MAX_BYTES) send(frame);
    else if (queue.length >= MAX_REQUESTS || queuedBytes + Buffer.byteLength(frame.wire) > MAX_BYTES)
      error(frame, -32001, "VoiceLayer reconnect queue is full");
    else { queue.push(frame); queuedBytes += Buffer.byteLength(frame.wire); }
  });
  process.stdin.on("data", data => {
    try { input(typeof data === "string" ? Buffer.from(data) : data); } catch { process.exitCode = 1; stop(); }
  });
  process.stdin.on("end", () => {
    ending = true;
    drain = setTimeout(() => {
      for (const frame of [...queue, ...pending.values()]) error(frame, -32000, "VoiceLayer stdin closed before response; request will not be retried.");
      stop();
    }, 1000);
    finish();
  });
  process.stdout.on("drain", () => { socket?.resume(); process.stdin.resume(); });
  process.stdout.on("error", stop);
  process.on("SIGTERM", stop); process.on("SIGINT", stop);
  connect();
}

if (import.meta.main) runBridge();
