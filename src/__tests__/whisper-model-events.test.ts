import { afterEach, expect, test } from "bun:test";
import {
  __resetWhisperServerStateForTests,
  __setWhisperServerTestHooksForTests,
  ensureServer,
  onWhisperModelStateChange,
  stopServer,
} from "../whisper-server";

afterEach(() => {
  __resetWhisperServerStateForTests(null);
  __setWhisperServerTestHooksForTests({});
});

test("adoption and stop emit model state changes without a health poll", async () => {
  const port = 28_179;
  let changes = 0;
  const unsubscribe = onWhisperModelStateChange(() => { changes++; });
  __setWhisperServerTestHooksForTests({
    isServerHealthy: async () => true,
    findPortListenerPids: () => [],
  });
  try {
    await ensureServer(port);
    expect(changes).toBe(1);
    stopServer();
    expect(changes).toBe(2);
  } finally {
    unsubscribe();
  }
});
