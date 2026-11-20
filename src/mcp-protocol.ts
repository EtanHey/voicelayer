/**
 * MCP protocol constants shared by the daemon handler, the Ask outbox and the tool schemas.
 *
 * MCP 2026-07-28 (modern, per-request `_meta`) is served alongside the legacy `initialize` handshake, which stays on
 * 2024-11-05. A dual-era client probes with `server/discover` first; any error sends it back to `initialize`.
 */
export const MODERN_PROTOCOL = "2026-07-28";
export const PROTOCOL_META = "io.modelcontextprotocol/protocolVersion";
export const CLIENT_CAPABILITIES_META = "io.modelcontextprotocol/clientCapabilities";
export const TASKS_EXTENSION = "io.modelcontextprotocol/tasks";
/** Longest a task-capable voice_ask blocks before returning its task (`wait_seconds`, clamped 0–90). */
export const MAX_WAIT_SECONDS = 90;
/** Suggested `tasks/get` interval. An answer arrives at human speed; Claude clamps this to 250–30000. */
export const TASK_POLL_MS = 2000;
