#!/usr/bin/env bun
import { createConnection, type Socket } from "node:net";
import { z } from "zod";
import { getMcpSocketPath } from "./paths";
import { MAX_NDJSON_LINE_BYTES } from "./ndjson-byte-framer";

const envelope = z.looseObject({
  jsonrpc: z.literal("2.0"),
  id: z.union([z.string(), z.number(), z.null()]).optional(),
  method: z.string().optional(),
});
type Message = z.infer<typeof envelope>;
type Frame = { wire: string; messages: Message[] };
const MAX_QUEUE_BYTES = 1024 * 1024;
const MAX_REQUESTS = 128;
const MAX_REPLAY_FAILURES = 3;
function parse(wire: string): Frame {
  const messages: Message[] = [];
  try {
    const value: unknown = JSON.parse(wire);
    for (const item of Array.isArray(value) ? value : [value]) {
      const parsed = envelope.safeParse(item);
      if (parsed.success) messages.push(parsed.data);
    }
  } catch {}
  return { wire, messages };
}
function frameReader(onFrame: (frame: Frame) => void, onOversize: () => void) {
  let parts: Buffer[] = [];
  let bytes = 0;
  let discarding = false;
  return (data: Buffer) => {
    let start = 0;
    while (start < data.length) {
      const newline = data.indexOf(10, start);
      const end = newline < 0 ? data.length : newline;
      const part = data.subarray(start, end);
      if (!discarding && bytes + part.length > MAX_NDJSON_LINE_BYTES) {
        discarding = true; parts = []; bytes = 0; onOversize();
      }
      if (!discarding && part.length) { parts.push(part); bytes += part.length; }
      if (newline < 0) break;
      if (!discarding && bytes) onFrame(parse(Buffer.concat(parts, bytes).toString("utf8") + "\n"));
      parts = []; bytes = 0; discarding = false; start = newline + 1;
    }
  };
}

export function runBridge() {
  let socket: Socket | undefined;
  let state: { kind: "offline" | "ready" } | { kind: "initialize" | "logging"; frame: Frame } = { kind: "offline" };
  let initialize: Frame | undefined;
  let initialized: Frame | undefined;
  let logging: Frame | undefined;
  let queue: Frame[] = [];
  let queuedBytes = 0;
  const pending = new Map<string | number | null, Message>();
  let delay = 100;
  let replayFailures = 0;
  let lastRetryLog = -Infinity;
  let retry: ReturnType<typeof setTimeout> | undefined;
  let handshake: ReturnType<typeof setTimeout> | undefined;
  let stable: ReturnType<typeof setTimeout> | undefined;
  let drain: ReturnType<typeof setTimeout> | undefined;
  let ending = false;
  let closed = false;
  const output = (wire: string) => {
    if (!process.stdout.write(wire)) { socket?.pause(); process.stdin.pause(); }
  };
  const error = (frame: Frame, code: number, message: string) => {
    for (const request of frame.messages) if (request.method && request.id !== undefined)
      output(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code, message } }) + "\n");
  };
  const stop = () => {
    closed = true; clearTimeout(retry); clearTimeout(handshake); clearTimeout(stable); clearTimeout(drain); socket?.destroy(); process.stdin.destroy();
  };
  const finish = () => { if (ending && !queue.length && !pending.size && state.kind !== "initialize" && state.kind !== "logging") stop(); };
  const rejectQueue = () => {
    for (const frame of queue) error(frame, -32000, "VoiceLayer session replay failed repeatedly; request was not sent.");
    queue = []; queuedBytes = 0;
  };
  const disconnect = () => {
    if (closed || state.kind === "offline" && retry) return;
    if ((state.kind === "initialize" || state.kind === "logging") && ++replayFailures >= MAX_REPLAY_FAILURES) rejectQueue();
    state = { kind: "offline" }; clearTimeout(handshake); clearTimeout(stable); socket?.destroy(); socket = undefined;
    for (const message of pending.values()) error({ wire: "", messages: [message] }, -32000, "VoiceLayer disconnected; execution may have occurred. Request will not be retried.");
    pending.clear();
    if (performance.now() - lastRetryLog >= 60_000) {
      process.stderr.write(JSON.stringify({ event: "mcp_bridge_reconnect", delayMs: delay }) + "\n");
      lastRetryLog = performance.now();
    }
    retry = setTimeout(connect, delay); delay = Math.min(delay * 2, 2000);
    finish();
  };
  const write = (wire: string) => {
    const current = socket;
    current?.write(wire, err => { if (socket !== current) return; if (err) disconnect(); else flush(); });
  };
  const singleton = (frame: Frame, message: Message): Frame => frame.messages.length === 1 && !frame.wire.trimStart().startsWith("[")
    ? frame : { wire: JSON.stringify(message) + "\n", messages: [message] };
  const send = (frame: Frame) => {
    const requests = frame.messages.filter(message => message.method && message.id !== undefined);
    const ids = requests.map(message => message.id);
    if (new Set(ids).size !== ids.length || ids.some(id => id !== undefined && pending.has(id)) || pending.size + requests.length > MAX_REQUESTS) {
      error(frame, -32001, "Too many outstanding requests or duplicate request ID"); return;
    }
    for (const message of frame.messages) {
      if (message.method && message.id !== undefined) pending.set(message.id, message);
      if (message.method === "initialize") initialize = singleton(frame, message);
      if (message.method === "notifications/initialized") initialized = singleton(frame, message);
    }
    write(frame.wire);
  };
  const canWrite = (frame: Frame) => socket && (socket.writableLength === 0 || socket.writableLength + Buffer.byteLength(frame.wire) <= MAX_QUEUE_BYTES);
  function flush() {
    while (state.kind === "ready" && queue.length) {
      const frame = queue[0];
      if (!canWrite(frame)) return;
      queue.shift(); queuedBytes -= Buffer.byteLength(frame.wire); send(frame);
    }
    finish();
  }
  const recovered = () => { delay = 100; lastRetryLog = -Infinity; };
  const ready = () => {
    clearTimeout(handshake); state = { kind: "ready" }; replayFailures = 0; recovered(); flush();
  };
  const receive = (frame: Frame) => {
    if (!frame.messages.length) return;
    if (state.kind === "initialize" || state.kind === "logging") {
      const replayId = state.frame.messages[0]?.id;
      const response = frame.messages.find(message => !message.method && message.id !== undefined && message.id === replayId);
      if (!response) return;
      if ("error" in response) { disconnect(); return; }
      if (state.kind === "initialize") {
        const queuedInitialized = queue.find(frame => frame.messages.length === 1 && frame.messages[0].method === "notifications/initialized");
        if (queuedInitialized) {
          queue = queue.filter(frame => frame !== queuedInitialized); queuedBytes -= Buffer.byteLength(queuedInitialized.wire);
        }
        initialized = queuedInitialized ?? initialized;
        write(initialized?.wire ?? '{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
        if (logging) { state = { kind: "logging", frame: logging }; write(logging.wire); }
        else ready();
      } else ready();
      const rest = frame.messages.filter(message => message !== response);
      if (rest.length) output(JSON.stringify(rest) + "\n");
      return;
    }
    recovered();
    for (const message of frame.messages) if (!message.method && message.id !== undefined) {
      const request = pending.get(message.id);
      if (request?.method === "logging/setLevel" && "result" in message && !("error" in message))
        logging = { wire: JSON.stringify(request) + "\n", messages: [request] };
      pending.delete(message.id);
    }
    output(frame.wire); finish();
  };
  function connect() {
    retry = undefined;
    if (closed) return;
    const current = createConnection(getMcpSocketPath()); socket = current;
    const read = frameReader(frame => { if (socket === current) receive(frame); }, () => {});
    current.on("connect", () => {
      if (initialize) {
        state = { kind: "initialize", frame: initialize }; write(initialize.wire);
        handshake = setTimeout(disconnect, 5000);
      } else { state = { kind: "ready" }; stable = setTimeout(recovered, 1000); flush(); }
    });
    current.on("data", data => { if (socket === current) read(typeof data === "string" ? Buffer.from(data) : data); });
    current.on("error", () => { if (socket === current) disconnect(); });
    current.on("close", () => { if (socket === current) disconnect(); });
    current.on("drain", () => { if (socket === current) flush(); });
  }
  const input = frameReader(frame => {
    if (state.kind !== "ready" && !frame.messages.length) {
      let id: string | number | null = null;
      let code = -32700;
      try {
        const value: unknown = JSON.parse(frame.wire); code = -32600;
        const parsed = envelope.pick({ id: true }).safeParse(value);
        if (parsed.success) id = parsed.data.id ?? null;
      } catch {}
      output(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message: "Invalid JSON-RPC frame" } }) + "\n"); return;
    }
    if (replayFailures >= MAX_REPLAY_FAILURES) { error(frame, -32000, "VoiceLayer session replay failed repeatedly; request was not sent."); return; }
    if (state.kind === "ready" && !queue.length && canWrite(frame)) send(frame);
    else if (queue.length >= MAX_REQUESTS || queuedBytes + Buffer.byteLength(frame.wire) > MAX_QUEUE_BYTES)
      error(frame, -32001, "VoiceLayer reconnect queue is full");
    else { queue.push(frame); queuedBytes += Buffer.byteLength(frame.wire); flush(); }
  }, () => output('{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Frame exceeds 16 MiB"}}\n'));
  process.stdin.on("data", data => input(typeof data === "string" ? Buffer.from(data) : data));
  process.stdin.on("end", () => {
    ending = true;
    drain = setTimeout(() => {
      for (const frame of [...queue, { wire: "", messages: [...pending.values()] }]) error(frame, -32000, "VoiceLayer stdin closed before response; request will not be retried.");
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
