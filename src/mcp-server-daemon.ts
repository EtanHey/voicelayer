#!/usr/bin/env bun
/**
 * VoiceLayer MCP Daemon — persistent singleton replacing per-session MCP processes.
 *
 * Listens on /tmp/voicelayer-mcp.sock for MCP clients (via socat).
 * Connects to Voice Bar on /tmp/voicelayer.sock for UI state.
 *
 * Resilience features:
 * - Orphan socket detection (probe before remove)
 * - Startup validation (refuse if another instance holds socket)
 * - Socket permissions (chmod 600)
 * - Health ping/pong endpoint
 * - Log rotation at 10MB
 * - Graceful shutdown (SIGTERM → flush, close, remove socket, release PID lock)
 *
 * Usage:
 *   bun src/mcp-server-daemon.ts
 *
 * MCP client config (.mcp.json):
 *   "voicelayer": { "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }
 */

import { getBackend } from "./stt";
import {
  DISABLE_VOICELAYER,
  MCP_SOCKET_PATH,
  isDefaultMcpSocketPath,
  isDefaultVoiceBarSocketPath,
  isVoicelayerDisabled,
  shouldAcceptVoiceBarCommands,
} from "./paths";
import {
  broadcast,
  connectToBar,
  disconnectFromBar,
  isConnected,
  onCommand,
} from "./socket-client";
import { handleSocketCommand } from "./socket-handlers";
import { createMcpDaemon, isSocketLive } from "./mcp-daemon";
import { getConnectionCount, getUptimeSeconds } from "./daemon-health";
import {
  isProcessAlive,
  readProcessCommandLine,
  resolveMcpPidOwnerStartup,
  resolveMcpSocketStartup,
  resolveOrphanStartupDecision,
} from "./daemon-startup";
import { resolvePython3Path } from "./tts-health";
import { acquireProcessLock, releaseProcessLock } from "./process-lock";
import { startLogRotation, stopLogRotation } from "./log-rotation";
import { initEnrichedPATH } from "./resolve-binary";
import {
  ensureSTTPolishServer,
  onSTTPolishServerStatus,
  stopSTTPolishServer,
} from "./stt-polish-server";
import {
  createSTTPolishStatusReporter,
  ensureAndReportSTTPolishServer,
} from "./stt-polish-daemon-status";
import {
  appendControlLayerEvent,
  startControlLayerHeartbeat,
  stopControlLayerHeartbeat,
} from "./control-layer-journal";
import {
  readProcessParentPid,
  resolveInitialParentPid,
  startParentProcessWatchdog,
  type ParentProcessWatchdog,
} from "./daemon-parent-watchdog";
import {
  handleVoiceSpeak,
  handleVoiceAsk,
  handleAnnounce,
  handleBrief,
  handleConsult,
  handleConverse,
  handleThink,
  handleReplay,
  handleToggle,
} from "./handlers";
import type { VoiceToolContext } from "./mcp-notifications";

// --- Tool dispatch table ---
const DISABLE_POLL_INTERVAL_MS = 5000;

const toolDispatch: Record<
  string,
  (args: Record<string, unknown>, context?: VoiceToolContext) => Promise<{
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  }>
> = {
  voice_speak: handleVoiceSpeak,
  voice_ask: handleVoiceAsk,
  qa_voice_announce: handleAnnounce,
  qa_voice_brief: handleBrief,
  qa_voice_consult: handleConsult,
  qa_voice_converse: handleConverse,
  qa_voice_think: handleThink,
  qa_voice_replay: handleReplay,
  qa_voice_toggle: handleToggle,
  qa_voice_say: handleAnnounce,
  qa_voice_ask: handleConverse,
};

// --- Startup ---

const ALLOW_ORPHAN_DAEMON_ENV = "VOICELAYER_ALLOW_ORPHAN_DAEMON";

async function main() {
  if (isVoicelayerDisabled()) {
    console.error(
      `[voicelayer-daemon] ${DISABLE_VOICELAYER}=1 or daemon disable flag present — exiting`,
    );
    process.exit(0);
  }

  const initialParentPid = resolveInitialParentPid();
  const orphanStartupDecision = resolveOrphanStartupDecision({
    initialParentPid,
    isParentAlive: isProcessAlive(initialParentPid),
    allowOrphan: process.env[ALLOW_ORPHAN_DAEMON_ENV] === "1",
  });
  if (orphanStartupDecision.action === "stand_down") {
    console.error(
      `[voicelayer-daemon] Refusing orphan startup (${orphanStartupDecision.reason}; parent PID ${initialParentPid}). VoiceBar.app must spawn the MCP daemon. Set ${ALLOW_ORPHAN_DAEMON_ENV}=1 only for isolated dev/QA runs.`,
    );
    process.exit(0);
  }

  // Enrich PATH before any binary resolution — captures login shell PATH
  // for LaunchAgent/VoiceBar context where /opt/homebrew/bin is missing
  const enrichedPath = initEnrichedPATH();
  console.error(
    `[voicelayer-daemon] PATH enriched (${enrichedPath.split(":").length} dirs)`,
  );

  // Startup validation: yield cleanly if another healthy daemon already owns
  // the socket. Exit 0 prevents launchd KeepAlive from tight-respawning a
  // redundant loser during VoiceBar/LaunchAgent contention.
  const socketStartupDecision = await resolveMcpSocketStartup({
    socketPath: MCP_SOCKET_PATH,
    isSocketLive,
    sleep: Bun.sleep,
    log: console.error,
  });
  if (socketStartupDecision.action === "stand_down") {
    process.exit(socketStartupDecision.exitCode);
  }

  // Acquire process lock after socket validation so a test or accidental start
  // against the live daily-driver socket cannot kill the existing daemon via
  // the PID file before discovering the socket is still owned.
  const lockResult = acquireProcessLock(undefined, { killAlive: false });
  let killedStalePid = lockResult.killedStale ? lockResult.stalePid : undefined;
  if (!lockResult.acquired) {
    const stalePid = lockResult.stalePid;
    if (typeof stalePid !== "number") {
      throw new Error("MCP PID lock refused acquisition without an owner PID");
    }
    const ownerDecision = await resolveMcpPidOwnerStartup({
      ownerPid: stalePid,
      socketPath: MCP_SOCKET_PATH,
      isSocketLive,
      sleep: Bun.sleep,
      log: console.error,
      readProcessCommand: readProcessCommandLine,
    });
    appendControlLayerEvent("daemon.pid_owner_live_decision", {
      owner_pid: stalePid,
      mcp_socket_path: MCP_SOCKET_PATH,
      action: ownerDecision.action,
      reason: ownerDecision.reason,
      owner_command_kind: ownerDecision.ownerCommandKind,
    });
    if (ownerDecision.action === "stand_down") {
      process.exit(0);
    }

    const reclaimResult = acquireProcessLock(undefined, { killAlive: true });
    if (!reclaimResult.acquired) {
      throw new Error(`Failed to reclaim MCP PID lock from PID ${stalePid}`);
    }
    killedStalePid = reclaimResult.killedStale
      ? reclaimResult.stalePid
      : killedStalePid;
  }
  if (killedStalePid !== undefined) {
    console.error(
      `[voicelayer-daemon] Killed orphan MCP server (PID ${killedStalePid})`,
    );
  }

  // Start log rotation (10MB threshold, 60s interval)
  startLogRotation();

  // Resolve python3 path early — LaunchAgent PATH may not include it
  const python3 = resolvePython3Path();
  console.error(`[voicelayer-daemon] python3: ${python3}`);

  try {
    await getBackend();
  } catch (err: unknown) {
    console.error(
      `[voicelayer-daemon] Warning: no STT backend — converse mode will fail`,
    );
    console.error(
      `[voicelayer-daemon]   ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  // Connect to Voice Bar for UI state
  const polishStatusReporter = createSTTPolishStatusReporter(broadcast);
  const unsubscribePolishStatus = onSTTPolishServerStatus((status) => {
    polishStatusReporter.report(status);
  });
  onCommand(handleSocketCommand);
  connectToBar(undefined, {
    role: "mcp-daemon",
    acceptsCommands: shouldAcceptVoiceBarCommands(),
    onConnected: () => polishStatusReporter.replay(),
  });
  void ensureAndReportSTTPolishServer({
    ensure: async () => {
      try {
        return await ensureSTTPolishServer();
      } catch (err: unknown) {
        console.error(
          `[voicelayer-daemon] STT polish server startup failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        appendControlLayerEvent(
          "transcription.polish_server_failed",
          { error: err instanceof Error ? err.message : String(err) },
          { topic: "voice.transcription" },
        );
        throw err;
      }
    },
    reporter: polishStatusReporter,
  });

  // Start MCP daemon (includes orphan socket cleanup and chmod 600)
  const daemon = await createMcpDaemon({
    socketPath: MCP_SOCKET_PATH,
    toolExecutor: {
      executeTool: async (name, args, context) => {
        const handler = toolDispatch[name];
        if (!handler) {
          return {
            content: [{ type: "text", text: `Unknown tool: ${name}` }],
            isError: true,
          };
        }
        return await handler(args, context);
      },
    },
    onNdjsonMessage: (msg) => {
      console.error(
        `[voicelayer-daemon] NDJSON message: ${JSON.stringify(msg)}`,
      );
    },
  });

  console.error(
    `[voicelayer-daemon] MCP daemon listening on ${MCP_SOCKET_PATH}`,
  );
  console.error(
    `[voicelayer-daemon] socat config: socat STDIO UNIX-CONNECT:${MCP_SOCKET_PATH}`,
  );
  appendControlLayerEvent("daemon.started", {
    mcp_socket_path: MCP_SOCKET_PATH,
    default_mcp_socket: isDefaultMcpSocketPath(),
    default_voicebar_socket: isDefaultVoiceBarSocketPath(),
    parent_pid: readProcessParentPid(),
    expected_parent_pid: resolveInitialParentPid(),
  });
  startControlLayerHeartbeat(() => ({
    uptime_seconds: getUptimeSeconds(),
    mcp_connections: getConnectionCount(),
    voicebar_connected: isConnected(),
    mcp_socket_path: MCP_SOCKET_PATH,
    parent_pid: readProcessParentPid(),
    expected_parent_pid: resolveInitialParentPid(),
  }));

  // Graceful shutdown: flush, close, remove socket, release PID lock
  let shuttingDown = false;
  let disablePollTimer: ReturnType<typeof setInterval> | null = null;
  let parentWatchdog: ParentProcessWatchdog | null = null;
  const shutdown = (reason = "signal") => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error("[voicelayer-daemon] Shutting down...");
    if (disablePollTimer) {
      clearInterval(disablePollTimer);
      disablePollTimer = null;
    }
    parentWatchdog?.stop();
    parentWatchdog = null;
    appendControlLayerEvent("daemon.shutdown", {
      reason,
      uptime_seconds: getUptimeSeconds(),
      mcp_connections: getConnectionCount(),
      voicebar_connected: isConnected(),
      parent_pid: readProcessParentPid(),
      expected_parent_pid: resolveInitialParentPid(),
    });
    stopControlLayerHeartbeat();
    stopLogRotation();
    unsubscribePolishStatus();
    stopSTTPolishServer();
    daemon.stop();
    disconnectFromBar();
    releaseProcessLock();
    console.error("[voicelayer-daemon] Shutdown complete.");
    process.exit(0);
  };

  parentWatchdog = startParentProcessWatchdog({
    onParentLost: (details) => {
      console.error(
        `[voicelayer-daemon] VoiceBar parent lost (expected ${details.initialParentPid}, current ${details.currentParentPid}) — shutting down`,
      );
      appendControlLayerEvent("daemon.parent_lost", {
        initial_parent_pid: details.initialParentPid,
        current_parent_pid: details.currentParentPid,
      });
      shutdown("parent_lost");
    },
  });

  disablePollTimer = setInterval(() => {
    if (!isVoicelayerDisabled()) return;
    console.error(
      "[voicelayer-daemon] Daemon disable flag detected — shutting down cleanly",
    );
    shutdown("disable_flag");
  }, DISABLE_POLL_INTERVAL_MS);

  process.on("SIGTERM", () => shutdown("sigterm"));
  process.on("SIGINT", () => shutdown("sigint"));
}

main().catch((err) => {
  console.error("[voicelayer-daemon] Fatal:", err);
  appendControlLayerEvent("daemon.fatal", {
    error: err instanceof Error ? err.message : String(err),
  });
  stopControlLayerHeartbeat();
  stopLogRotation();
  disconnectFromBar();
  releaseProcessLock();
  process.exit(1);
});
