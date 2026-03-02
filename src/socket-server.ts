/**
 * Re-export facade — preserves existing import paths during architecture inversion.
 *
 * AIDEV-NOTE: This file is a temporary shim. All callers import from "./socket-server"
 * and get the new client-side implementation from "./socket-client". The facade will
 * be removed in PR 2 when all imports are updated directly to "./socket-client".
 *
 * Mapping:
 *   startSocketServer  → connectToFlowBar  (was: Bun.listen, now: Bun.connect)
 *   stopSocketServer   → disconnectFromFlowBar
 *   isServerRunning    → isConnected
 *   broadcast          → broadcast (unchanged API)
 *   onCommand          → onCommand (unchanged API)
 */

import {
  connectToFlowBar,
  disconnectFromFlowBar,
  broadcast,
  onCommand,
  isConnected,
} from "./socket-client";

export {
  connectToFlowBar as startSocketServer,
  disconnectFromFlowBar as stopSocketServer,
  broadcast,
  onCommand,
  isConnected as isServerRunning,
};

// AIDEV-NOTE: getClientCount() is no longer meaningful — MCP is a single client now.
// Exported for backward compat; always returns 0 or 1.
export function getClientCount(): number {
  return isConnected() ? 1 : 0;
}
