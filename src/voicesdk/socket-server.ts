import { existsSync, unlinkSync } from "fs";
import {
  parseVoiceSdkCommand,
  serializeVoiceSdkEvent,
  type VoiceSdkCommand,
  type VoiceSdkEvent,
} from "./protocol";
import type { VoiceSdkSessionManager } from "./session";

interface VoiceSdkClientState {
  buffer: string;
  queue: Promise<void>;
}

export interface VoiceSdkSocketWriter {
  write(payload: string): number;
  end(): void;
}

export interface VoiceSdkSocketServerOptions {
  socketPath: string;
  manager: VoiceSdkSessionManager;
  maxBufferedEventsPerClient?: number;
  writerFactory?: (socket: VoiceSdkSocketWriter) => VoiceSdkSocketWriter;
}

export interface VoiceSdkSocketServer {
  stop(): void;
  getClientCount(): number;
}

interface Client {
  writer: VoiceSdkSocketWriter;
  bufferedEvents: number;
}

export function createVoiceSdkSocketServer(
  options: VoiceSdkSocketServerOptions,
): VoiceSdkSocketServer {
  const clients = new Set<Client>();
  const maxBufferedEvents = options.maxBufferedEventsPerClient ?? 128;

  if (existsSync(options.socketPath)) {
    unlinkSync(options.socketPath);
  }

  const unsubscribe = options.manager.subscribe((event) => {
    broadcast(event);
  });

  const server = Bun.listen<VoiceSdkClientState>({
    unix: options.socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "", queue: Promise.resolve() };
        clients.add({
          writer: options.writerFactory?.(socket) ?? socket,
          bufferedEvents: 0,
        });
      },
      data(socket, raw) {
        socket.data.buffer += raw.toString("utf-8");
        const lines = socket.data.buffer.split("\n");
        socket.data.buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const command = parseVoiceSdkCommand(line);
          if (!command) continue;
          socket.data.queue = socket.data.queue
            .then(() => handleCommand(options.manager, command))
            .catch((error) => {
              writeError(socket, error);
            });
        }
      },
      close(socket) {
        removeClient(socket);
      },
      error(socket) {
        removeClient(socket);
      },
      drain(socket) {
        const client = clientFor(socket);
        if (client) client.bufferedEvents = 0;
      },
    },
  });

  function broadcast(event: VoiceSdkEvent): void {
    const payload = serializeVoiceSdkEvent(event);
    for (const client of [...clients]) {
      try {
        const written = client.writer.write(payload);
        if (written === 0) {
          client.bufferedEvents += 1;
          if (client.bufferedEvents > maxBufferedEvents) {
            client.writer.end();
            clients.delete(client);
          }
        } else {
          client.bufferedEvents = 0;
        }
      } catch {
        clients.delete(client);
      }
    }
  }

  function removeClient(socket: VoiceSdkSocketWriter): void {
    const client = clientFor(socket);
    if (client) clients.delete(client);
  }

  function clientFor(socket: VoiceSdkSocketWriter): Client | undefined {
    for (const client of clients) {
      if (client.writer === socket) return client;
    }
    return undefined;
  }

  return {
    stop() {
      unsubscribe();
      server.stop(true);
      try {
        unlinkSync(options.socketPath);
      } catch {}
    },
    getClientCount() {
      return clients.size;
    },
  };
}

async function handleCommand(
  manager: VoiceSdkSessionManager,
  command: VoiceSdkCommand,
): Promise<void> {
  switch (command.cmd) {
    case "session.start":
      await manager.startSession({
        product: command.product,
        ...(command.artifact_id ? { artifact_id: command.artifact_id } : {}),
      });
      break;
    case "section.start":
      await manager.startSection(command.session_id, {
        section_id: command.section_id,
        title: command.title,
        ordinal: command.ordinal,
      });
      break;
    case "speak":
      await manager.speak(command.session_id, {
        text: command.text,
        ...(command.voice_id ? { voice_id: command.voice_id } : {}),
      });
      break;
    case "listen":
      await manager.listen(command.session_id, {
        ...(command.mode ? { mode: command.mode } : {}),
        ...(command.timeout_ms ? { timeout_ms: command.timeout_ms } : {}),
      });
      break;
    case "decision.record":
      await manager.recordDecision(command.session_id, {
        artifact_ref: command.artifact_ref,
        summary: command.summary,
        status: command.status,
      });
      break;
    case "session.end":
      await manager.endSession(command.session_id, command.reason);
      break;
  }
}

function writeError(
  socket: { write: (payload: string) => number },
  error: unknown,
): void {
  try {
    socket.write(
      JSON.stringify({
        type: "error",
        message: error instanceof Error ? error.message : String(error),
      }) + "\n",
    );
  } catch {}
}
