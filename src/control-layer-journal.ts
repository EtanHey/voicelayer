import { Database } from "bun:sqlite";
import { mkdirSync, realpathSync, statSync, writeFileSync } from "fs";
import { homedir } from "os";
import { dirname, join, resolve } from "path";

const DEFAULT_HEARTBEAT_INTERVAL_MS = 5_000;

let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

export function appendControlLayerEvent(
  type: string,
  payload: Record<string, unknown>,
  options: { topic?: string; seat?: string | null } = {},
): void {
  if (process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL === "1") return;

  try {
    const base = orcBase();
    const dbPath = resolve(base, "fleet-journal.db");
    const markersDir = resolve(base, "markers");
    mkdirSync(dirname(dbPath), { recursive: true });
    mkdirSync(markersDir, { recursive: true });

    const topic = options.topic ?? "voice.health";
    const db = new Database(dbPath);
    try {
      db.exec("PRAGMA busy_timeout=1000;");
      db.exec("PRAGMA journal_mode=WAL;");
      db.exec(`
        CREATE TABLE IF NOT EXISTS events (
          seq          INTEGER PRIMARY KEY AUTOINCREMENT,
          ts           TEXT NOT NULL,
          topic        TEXT NOT NULL,
          seat         TEXT,
          type         TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          ack_state    TEXT NOT NULL DEFAULT 'none'
        );
      `);
      const row = db
        .query(
          `INSERT INTO events (ts, topic, seat, type, payload_json, ack_state)
           VALUES (?, ?, ?, ?, ?, 'none')
           RETURNING seq`,
        )
        .get(
          new Date().toISOString(),
          topic,
          options.seat ?? null,
          type,
          JSON.stringify({
            component: "voicelayer",
            pid: process.pid,
            ...payload,
          }),
        ) as { seq: number };
      writeFileSync(resolve(markersDir, tagForTopic(topic)), `${row.seq}\n`);
    } finally {
      db.close();
    }
  } catch (error) {
    console.error(
      `[voicelayer] ControlLayer journal write failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

export function startControlLayerHeartbeat(
  payload: () => Record<string, unknown>,
  intervalMs = DEFAULT_HEARTBEAT_INTERVAL_MS,
): void {
  stopControlLayerHeartbeat();
  appendControlLayerEvent("daemon.heartbeat", payload());
  heartbeatTimer = setInterval(() => {
    appendControlLayerEvent("daemon.heartbeat", payload());
  }, intervalMs);
  heartbeatTimer.unref();
}

export function stopControlLayerHeartbeat(): void {
  if (!heartbeatTimer) return;
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

function orcBase(): string {
  const override = process.env.VOICELAYER_CONTROL_LAYER_BASE?.trim();
  if (override) return resolve(override);

  const home = realpathSync(homedir());
  const stats = statSync(home);
  if (!stats.isDirectory()) {
    throw new Error(`HOME is not a directory: ${home}`);
  }
  return join(home, ".local/share/orc");
}

function tagForTopic(topic: string): string {
  const tag = topic.replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
  return tag || "root";
}
