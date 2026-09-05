import { describe, it, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  __clearWhisperServerLaunchRecordForTests,
  __resetWhisperServerStateForTests,
  __setWhisperServerTestHooksForTests,
  buildWhisperServerLaunchPlan,
  ensureServer,
  isServerAvailable,
  isServerHealthy,
  readWhisperServerHelpText,
  resolveWhisperAccelerationPlan,
  stopServer,
  transcribeViaServer,
  whisperServerLaunchRecord,
} from "../whisper-server";
import {
  clearWhisperServerOwnership,
  portOwnerPids,
  readWhisperServerOwnership,
  writeWhisperServerOwnership,
} from "../whisper-server-ownership";
import {
  parseWhisperPerformanceEffort,
  whisperPerformanceArgsForEffort,
} from "../whisper-performance";

describe("whisper-server", () => {
  // Ownership records are real files. Point the whole suite at a scratch dir so
  // a test launch never stamps a bogus owner into ~/.local/state/voicelayer/.
  let ownershipDir = "";
  let previousOwnershipDir: string | undefined;

  beforeAll(() => {
    previousOwnershipDir = process.env.VOICELAYER_WHISPER_OWNERSHIP_DIR;
    ownershipDir = mkdtempSync(join(tmpdir(), "voicelayer-whisper-owner-"));
    process.env.VOICELAYER_WHISPER_OWNERSHIP_DIR = ownershipDir;
  });

  afterAll(() => {
    if (previousOwnershipDir === undefined) {
      delete process.env.VOICELAYER_WHISPER_OWNERSHIP_DIR;
    } else {
      process.env.VOICELAYER_WHISPER_OWNERSHIP_DIR = previousOwnershipDir;
    }
    rmSync(ownershipDir, { recursive: true, force: true });
  });
  describe("isServerAvailable", () => {
    it("returns a boolean", () => {
      const result = isServerAvailable();
      expect(typeof result).toBe("boolean");
    });

    it("checks for both binary and model", () => {
      // isServerAvailable is a pure sync check — no side effects
      const result = isServerAvailable();
      expect(typeof result).toBe("boolean");
    });
  });

  describe("isServerHealthy", () => {
    it("returns false when no server is running", async () => {
      // Use a random port that won't have a server
      const healthy = await isServerHealthy(59999);
      expect(healthy).toBe(false);
    });

    it("returns false on unreachable port", async () => {
      const healthy = await isServerHealthy(1);
      expect(healthy).toBe(false);
    });
  });

  describe("acceleration planning", () => {
    const serverHelp = `
usage: whisper-server [options]
  -ng,       --no-gpu            [false  ] do not use gpu
  -fa,       --flash-attn        [true   ] enable flash attention
`;

    it("falls back Core ML requests to Metal when the binary has no Core ML runtime support", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "coreml",
        helpText: serverHelp,
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        coreMLModelPath: "/tmp/large-v3-turbo.mlpackage",
        exists: () => true,
      });

      expect(plan.requested).toBe("coreml");
      expect(plan.mode).toBe("metal");
      expect(plan.args).not.toContain("--no-gpu");
      expect(plan.env.GGML_METAL_PATH_RESOURCES).toBe(
        "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
      );
      expect(plan.warnings.join("\n")).toContain("Core ML requested");
      expect(plan.warnings.join("\n")).toContain("no Core ML runtime flag");
    });

    it("does not treat negative Core ML option names as runtime support", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "coreml",
        helpText: "--no-coreml     disable Core ML",
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        coreMLModelPath: "/tmp/large-v3-turbo.mlpackage",
        exists: () => true,
      });

      expect(plan.mode).toBe("metal");
      expect(plan.args).not.toContain("--no-coreml");
    });

    it("uses exact Core ML runtime option tokens when available", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "coreml",
        helpText: "--coreml-model PATH     Core ML model package",
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        coreMLModelPath: "/tmp/large-v3-turbo.mlpackage",
        exists: () => true,
      });

      expect(plan.mode).toBe("coreml");
      expect(plan.args).toEqual([
        "--coreml-model",
        "/tmp/large-v3-turbo.mlpackage",
      ]);
    });

    it("does not append the .mlpackage path to boolean Core ML flags", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "coreml",
        helpText: "--coreml     enable Core ML acceleration",
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        coreMLModelPath: "/tmp/large-v3-turbo.mlpackage",
        exists: () => true,
      });

      expect(plan.mode).toBe("coreml");
      expect(plan.args).toEqual(["--coreml"]);
    });

    it("falls back Core ML requests when the .mlpackage path is missing", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "coreml",
        helpText: `${serverHelp}\n  --coreml-model PATH`,
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        coreMLModelPath: "/tmp/missing.mlpackage",
        exists: () => false,
      });

      expect(plan.mode).toBe("metal");
      expect(plan.warnings.join("\n")).toContain("does not exist");
    });

    it("uses CPU mode only when explicitly requested", () => {
      const plan = resolveWhisperAccelerationPlan({
        requested: "cpu",
        helpText: serverHelp,
        metalResourcesPath: "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        exists: () => true,
      });

      expect(plan.mode).toBe("cpu");
      expect(plan.args).toContain("--no-gpu");
      expect(plan.env.GGML_METAL_PATH_RESOURCES).toBeUndefined();
    });

    it("builds launch args with the selected acceleration plan", () => {
      const launch = buildWhisperServerLaunchPlan({
        binary: "/opt/homebrew/bin/whisper-server",
        model: "/Users/me/.cache/whisper/ggml-large-v3-turbo.bin",
        port: 18878,
        helpText: serverHelp,
        requestedAcceleration: "cpu",
        inheritedEnv: { PATH: "/opt/homebrew/bin" },
        exists: () => true,
      });

      expect(launch.args).toEqual([
        "/opt/homebrew/bin/whisper-server",
        "-m",
        "/Users/me/.cache/whisper/ggml-large-v3-turbo.bin",
        "--port",
        "18878",
        "--host",
        "127.0.0.1",
        "-t",
        "4",
        "-bo",
        "5",
        "-bs",
        "5",
        "--no-gpu",
      ]);
      expect(launch.env.PATH).toBe("/opt/homebrew/bin");
      expect(launch.acceleration.mode).toBe("cpu");
      expect(launch.args).not.toContain("-nt");
      expect(launch.args).not.toContain("--no-timestamps");
    });

    it("maps performance effort to whisper beam/search args", () => {
      expect(whisperPerformanceArgsForEffort("fast")).toEqual([
        "-bo",
        "1",
        "-bs",
        "1",
      ]);
      expect(whisperPerformanceArgsForEffort("balanced")).toEqual([
        "-bo",
        "3",
        "-bs",
        "3",
      ]);
      expect(whisperPerformanceArgsForEffort("accurate")).toEqual([
        "-bo",
        "5",
        "-bs",
        "5",
      ]);
      expect(parseWhisperPerformanceEffort("FAST")).toBe("fast");
      expect(parseWhisperPerformanceEffort("invalid")).toBeNull();
    });

    it("uses the requested performance effort in launch args", () => {
      const launch = buildWhisperServerLaunchPlan({
        binary: "/opt/homebrew/bin/whisper-server",
        model: "/Users/me/.cache/whisper/ggml-large-v3-turbo.bin",
        port: 18878,
        helpText: serverHelp,
        performanceEffort: "balanced",
        inheritedEnv: { PATH: "/opt/homebrew/bin" },
        exists: () => true,
      });

      const boIndex = launch.args.indexOf("-bo");
      const bsIndex = launch.args.indexOf("-bs");
      expect(launch.args.slice(boIndex, boIndex + 2)).toEqual(["-bo", "3"]);
      expect(launch.args.slice(bsIndex, bsIndex + 2)).toEqual(["-bs", "3"]);
    });

    it("bounds whisper-server help probing and falls back to no help text on failure", () => {
      const result = readWhisperServerHelpText(
        "/opt/homebrew/bin/whisper-server",
        () =>
          ({
            stdout: "",
            stderr: "",
            status: null,
            error: Object.assign(new Error("spawn ETIMEDOUT"), {
              code: "ETIMEDOUT",
            }),
          }) as any,
      );

      expect(result.helpText).toBe("");
      expect(result.warning).toContain("failed");
      expect(result.warning).toContain("falling back");
    });
  });

  describe("ensureServer lifecycle", () => {
    it("does not publish a launch record when our child lost the port race", async () => {
      // The health check only proves *something* answers on the port. Here our
      // child died on startup and another process is serving: adopting it would
      // stamp every recording with a binary, args and PID that never produced
      // the transcript.
      let healthy = false;
      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        spawn: () => {
          // Our child died immediately; something else is answering the port.
          healthy = true;
          return {
            pid: 31337,
            stderr: null,
            kill: () => {},
            exitCode: 1,
          };
        },
        isServerHealthy: async () => healthy,
        findPortListenerPids: () => [99999],
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        __clearWhisperServerLaunchRecordForTests();
        await expect(ensureServer(18991)).rejects.toThrow(
          /failed to start within/,
        );
        expect(whisperServerLaunchRecord()).toBe(null);
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
        __clearWhisperServerLaunchRecordForTests();
      }
    });

    it("does not publish a launch record when another PID owns the healthy port", async () => {
      // Child still alive, but lsof says the listener is somebody else.
      let healthy = false;
      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        spawn: () => {
          healthy = true;
          return {
            pid: 31338,
            stderr: null,
            kill: () => {},
            exitCode: null,
          };
        },
        isServerHealthy: async () => healthy,
        findPortListenerPids: () => [70001],
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        __clearWhisperServerLaunchRecordForTests();
        await expect(ensureServer(18992)).rejects.toThrow(
          /failed to start within/,
        );
        expect(whisperServerLaunchRecord()).toBe(null);
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
        __clearWhisperServerLaunchRecordForTests();
      }
    });

    it("publishes the launch record when our own child owns the healthy port", async () => {
      let healthy = false;
      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        spawn: () => {
          healthy = true;
          return {
            pid: 31339,
            stderr: null,
            kill: () => {},
            exitCode: null,
          };
        },
        isServerHealthy: async () => healthy,
        findPortListenerPids: () => [31339],
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        __clearWhisperServerLaunchRecordForTests();
        await expect(ensureServer(18993)).resolves.toBe(18993);
        const record = whisperServerLaunchRecord();
        expect(record?.pid).toBe(31339);
        expect(record?.binary).toBe("/tmp/whisper-server");
        expect(typeof record?.startedAt).toBe("string");
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
        __clearWhisperServerLaunchRecordForTests();
      }
    });

    it("coalesces concurrent launches for the same port", async () => {
      let healthy = false;
      let spawnCalls = 0;

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        spawn: () => {
          spawnCalls += 1;
          healthy = true;
          return {
            pid: 12345,
            stderr: null,
            kill: () => {},
          };
        },
        isServerHealthy: async () => healthy,
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        const [first, second] = await Promise.all([
          ensureServer(18881),
          ensureServer(18881),
        ]);

        expect(first).toBe(18881);
        expect(second).toBe(18881);
        expect(spawnCalls).toBe(1);
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });

    it("skips help probing when Core ML is not requested", async () => {
      const previousAcceleration = process.env.QA_VOICE_WHISPER_ACCELERATION;
      process.env.QA_VOICE_WHISPER_ACCELERATION = "metal";

      let healthy = false;
      let helpProbeCalls = 0;

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => {
          helpProbeCalls += 1;
          return { helpText: "--coreml  enable Core ML" };
        },
        spawn: () => {
          healthy = true;
          return {
            pid: 12346,
            stderr: null,
            kill: () => {},
          };
        },
        isServerHealthy: async () => healthy,
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(18884)).resolves.toBe(18884);
        expect(helpProbeCalls).toBe(0);
      } finally {
        if (previousAcceleration === undefined) {
          delete process.env.QA_VOICE_WHISPER_ACCELERATION;
        } else {
          process.env.QA_VOICE_WHISPER_ACCELERATION = previousAcceleration;
        }
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });

    it("reclaims a wedged whisper-server that fails the health page before launching its own sidecar", async () => {
      // Reclaim survives, but only for an occupant that does NOT answer /health.
      // A wedged server holds the port without serving; nothing else can bind.
      let wedgedServerAlive = true;
      let managedServerHealthy = false;
      let spawnCalls = 0;
      const killed: Array<{ pid: number; signal: string }> = [];

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        findExternalWhisperServerPids: () => (wedgedServerAlive ? [99881] : []),
        killExternalPid: (pid, signal) => {
          killed.push({ pid, signal });
          wedgedServerAlive = false;
        },
        isPidAlive: (pid) => pid === 99881 && wedgedServerAlive,
        spawn: () => {
          spawnCalls += 1;
          managedServerHealthy = true;
          return {
            pid: 12348,
            stderr: null,
            kill: () => {},
          };
        },
        // The wedged occupant never answers the health page.
        isServerHealthy: async () => managedServerHealthy,
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(18886)).resolves.toBe(18886);
        expect(killed).toEqual([{ pid: 99881, signal: "SIGTERM" }]);
        expect(spawnCalls).toBe(1);
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
        __clearWhisperServerLaunchRecordForTests();
      }
    });

    it("adopts an unidentified healthy occupant instead of refusing the port", async () => {
      // Previously this threw "already occupied by a non-VoiceLayer process".
      // A healthy occupant we cannot identify is still someone's live server:
      // use it, do not refuse and do not kill it.
      let spawnCalls = 0;
      const killed: Array<{ pid: number; signal: string }> = [];

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        findExternalWhisperServerPids: () => [],
        findPortListenerPids: () => [],
        killExternalPid: (pid, signal) => killed.push({ pid, signal }),
        spawn: () => {
          spawnCalls += 1;
          return { pid: 12349, stderr: null, kill: () => {} };
        },
        isServerHealthy: async () => true,
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(18887)).resolves.toBe(18887);
        expect(killed).toEqual([]);
        expect(spawnCalls).toBe(0);
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
        __clearWhisperServerLaunchRecordForTests();
      }
    });

    it("retries with Metal when Core ML startup fails", async () => {
      const previousAcceleration = process.env.QA_VOICE_WHISPER_ACCELERATION;
      process.env.QA_VOICE_WHISPER_ACCELERATION = "coreml";

      let launchMode: "coreml" | "metal" | null = null;
      const launchModes: Array<"coreml" | "metal"> = [];

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "--coreml  enable Core ML" }),
        spawn: (args) => {
          launchMode = args.includes("--coreml") ? "coreml" : "metal";
          launchModes.push(launchMode);
          return {
            pid: launchModes.length,
            stderr: null,
            kill: () => {},
          };
        },
        isServerHealthy: async () => launchMode === "metal",
        sleep: async () => {},
        startupTimeoutMs: 5,
      });

      try {
        await expect(ensureServer(18882)).resolves.toBe(18882);
        expect(launchModes).toEqual(["coreml", "metal"]);
      } finally {
        if (previousAcceleration === undefined) {
          delete process.env.QA_VOICE_WHISPER_ACCELERATION;
        } else {
          process.env.QA_VOICE_WHISPER_ACCELERATION = previousAcceleration;
        }
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });

    it("reports the active startup timeout in launch failures", async () => {
      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "" }),
        spawn: () => ({
          pid: 12347,
          stderr: null,
          kill: () => {},
        }),
        isServerHealthy: async () => false,
        sleep: async () => {},
        startupTimeoutMs: 5,
      });

      try {
        await expect(ensureServer(18885)).rejects.toThrow(
          "whisper-server failed to start within 0.005s",
        );
      } finally {
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });

    it("waits for a failed Core ML process to exit before Metal retry", async () => {
      const previousAcceleration = process.env.QA_VOICE_WHISPER_ACCELERATION;
      process.env.QA_VOICE_WHISPER_ACCELERATION = "coreml";

      let launchMode: "coreml" | "metal" | null = null;
      let coreMLExited = false;
      let resolveCoreMLExit: (code: number) => void = () => {};
      const launchModes: Array<"coreml" | "metal"> = [];

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => "/tmp/ggml-large-v3-turbo.bin",
        readHelpText: () => ({ helpText: "--coreml  enable Core ML" }),
        spawn: (args) => {
          launchMode = args.includes("--coreml") ? "coreml" : "metal";
          launchModes.push(launchMode);

          if (launchMode === "coreml") {
            return {
              pid: 1,
              stderr: null,
              exited: new Promise<number>((resolve) => {
                resolveCoreMLExit = resolve;
              }).then((code) => {
                coreMLExited = true;
                return code;
              }),
              kill: () => {
                setTimeout(() => resolveCoreMLExit(0), 0);
              },
            };
          }

          expect(coreMLExited).toBe(true);
          return {
            pid: 2,
            stderr: null,
            kill: () => {},
          };
        },
        isServerHealthy: async () => launchMode === "metal",
        sleep: async () => {},
        startupTimeoutMs: 5,
      });

      try {
        await expect(ensureServer(18883)).resolves.toBe(18883);
        expect(launchModes).toEqual(["coreml", "metal"]);
      } finally {
        if (previousAcceleration === undefined) {
          delete process.env.QA_VOICE_WHISPER_ACCELERATION;
        } else {
          process.env.QA_VOICE_WHISPER_ACCELERATION = previousAcceleration;
        }
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });
  });

  describe("ownership guard", () => {
    // AIDEV-NOTE: The regression these tests exist for — 2026-09-05, five live
    // whisper-server kills in one evening. Any second process (a worker script,
    // `bun test`, the corpus verify daemon) called ensureServer(), found a
    // healthy daemon-owned server on the port, saw its own serverState was
    // null, called it a stale orphan and SIGKILLed it. Each kill cost Etan a
    // cold model load on his next dictation.
    const FAKE_MODEL = "/tmp/ggml-large-v3-turbo.bin";

    function startFakeHealthyServer(): {
      port: number;
      stop: () => void;
      alive: () => Promise<boolean>;
    } {
      const server = Bun.serve({
        port: 0,
        fetch(req) {
          if (new URL(req.url).pathname === "/health") {
            return Response.json({ status: "ok" });
          }
          return new Response("not found", { status: 404 });
        },
      });
      return {
        port: server.port,
        stop: () => server.stop(true),
        alive: async () => {
          try {
            const resp = await fetch(`http://127.0.0.1:${server.port}/health`);
            return resp.ok;
          } catch {
            return false;
          }
        },
      };
    }

    function resetWhisperServerModule(): void {
      __setWhisperServerTestHooksForTests({});
      __resetWhisperServerStateForTests(null);
      __clearWhisperServerLaunchRecordForTests();
    }

    it("adopts a healthy server another process launched instead of killing it", async () => {
      const fake = startFakeHealthyServer();
      const killed: Array<{ pid: number; signal: string }> = [];
      let spawnCalls = 0;

      writeWhisperServerOwnership(fake.port, {
        pid: process.pid,
        owner_pid: process.pid,
        started_at: "2026-09-05T18:40:00.000Z",
        binary: "/opt/homebrew/bin/whisper-server",
        args: [
          "/opt/homebrew/bin/whisper-server",
          "-m",
          FAKE_MODEL,
          "--port",
          String(fake.port),
        ],
        model_path: FAKE_MODEL,
        performance_effort: "accurate",
        acceleration_mode: "metal",
      });

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        // Pretend the reclaim helper WOULD find a killable target: the guard
        // must refuse to kill it anyway.
        findExternalWhisperServerPids: () => [process.pid],
        killExternalPid: (pid, signal) => killed.push({ pid, signal }),
        findPortListenerPids: () => [process.pid],
        spawn: () => {
          spawnCalls += 1;
          return { pid: 4242, stderr: null, kill: () => {} };
        },
        sleep: async () => {},
        startupTimeoutMs: 25,
        // isServerHealthy deliberately NOT stubbed: the real health check runs
        // against the real fake server above.
      });

      try {
        await expect(ensureServer(fake.port)).resolves.toBe(fake.port);
        expect(killed).toEqual([]);
        expect(spawnCalls).toBe(0);
        expect(await fake.alive()).toBe(true);

        const record = whisperServerLaunchRecord();
        expect(record?.adopted).toBe(true);
        expect(record?.ownerPid).toBe(process.pid);
        expect(record?.pid).toBe(process.pid);
        expect(record?.modelPath).toBe(FAKE_MODEL);
        expect(record?.startedAt).toBe("2026-09-05T18:40:00.000Z");
      } finally {
        resetWhisperServerModule();
        clearWhisperServerOwnership(fake.port);
        fake.stop();
      }
    });

    it("adopts a healthy server with no ownership record rather than killing it", async () => {
      const fake = startFakeHealthyServer();
      const killed: Array<{ pid: number; signal: string }> = [];
      let spawnCalls = 0;

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        findExternalWhisperServerPids: () => [777001],
        killExternalPid: (pid, signal) => killed.push({ pid, signal }),
        findPortListenerPids: () => [777001],
        spawn: () => {
          spawnCalls += 1;
          return { pid: 4243, stderr: null, kill: () => {} };
        },
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(fake.port)).resolves.toBe(fake.port);
        expect(killed).toEqual([]);
        expect(spawnCalls).toBe(0);
        expect(await fake.alive()).toBe(true);
        // No ownership record means no provenance: reporting the flags we
        // *would* have used would be a guess, not provenance.
        expect(whisperServerLaunchRecord()).toBeNull();
      } finally {
        resetWhisperServerModule();
        fake.stop();
      }
    });

    it("adopts a server whose ownership record names a dead pid", async () => {
      const fake = startFakeHealthyServer();
      const killed: Array<{ pid: number; signal: string }> = [];

      writeWhisperServerOwnership(fake.port, {
        pid: 777002,
        owner_pid: 777003,
        started_at: "2026-09-05T18:00:00.000Z",
        binary: "/opt/homebrew/bin/whisper-server",
        args: ["/opt/homebrew/bin/whisper-server", "--port", String(fake.port)],
        model_path: FAKE_MODEL,
        performance_effort: "accurate",
        acceleration_mode: "metal",
      });

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        findExternalWhisperServerPids: () => [777004],
        killExternalPid: (pid, signal) => killed.push({ pid, signal }),
        findPortListenerPids: () => [777004],
        isPidAlive: () => false,
        spawn: () => {
          throw new Error("must not relaunch over a healthy server");
        },
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(fake.port)).resolves.toBe(fake.port);
        expect(killed).toEqual([]);
        expect(await fake.alive()).toBe(true);
        expect(whisperServerLaunchRecord()).toBeNull();
      } finally {
        resetWhisperServerModule();
        clearWhisperServerOwnership(fake.port);
        fake.stop();
      }
    });

    it("records a flag mismatch on the adopted server instead of killing it", async () => {
      const fake = startFakeHealthyServer();
      const killed: Array<{ pid: number; signal: string }> = [];

      writeWhisperServerOwnership(fake.port, {
        pid: process.pid,
        owner_pid: process.pid,
        started_at: "2026-09-05T18:40:00.000Z",
        binary: "/opt/homebrew/bin/whisper-server",
        args: ["/opt/homebrew/bin/whisper-server", "--port", String(fake.port)],
        model_path: "/tmp/ggml-base.en.bin",
        performance_effort: "fast",
        acceleration_mode: "cpu",
      });

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        // This process would have launched a different model entirely.
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        findExternalWhisperServerPids: () => [process.pid],
        killExternalPid: (pid, signal) => killed.push({ pid, signal }),
        findPortListenerPids: () => [process.pid],
        spawn: () => {
          throw new Error("must not relaunch over a healthy server");
        },
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(fake.port)).resolves.toBe(fake.port);
        expect(killed).toEqual([]);
        expect(await fake.alive()).toBe(true);
        const record = whisperServerLaunchRecord();
        expect(record?.adopted).toBe(true);
        expect(record?.flagsMatch).toBe(false);
        expect(record?.modelPath).toBe("/tmp/ggml-base.en.bin");
      } finally {
        resetWhisperServerModule();
        clearWhisperServerOwnership(fake.port);
        fake.stop();
      }
    });

    it("does not stop an adopted server on shutdown", async () => {
      // process.on("exit", stopServer) is a kill path too: a `bun test` run
      // that adopted the live server must not take it down when it exits.
      const fake = startFakeHealthyServer();

      writeWhisperServerOwnership(fake.port, {
        pid: process.pid,
        owner_pid: process.pid,
        started_at: "2026-09-05T18:40:00.000Z",
        binary: "/opt/homebrew/bin/whisper-server",
        args: ["/opt/homebrew/bin/whisper-server", "--port", String(fake.port)],
        model_path: FAKE_MODEL,
        performance_effort: "accurate",
        acceleration_mode: "metal",
      });

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        findPortListenerPids: () => [process.pid],
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(fake.port)).resolves.toBe(fake.port);
        stopServer();
        expect(await fake.alive()).toBe(true);
        // The adopted server's ownership record belongs to its launcher; a
        // non-owner shutdown must leave it in place.
        expect(whisperServerLaunchRecord()).toBeNull();
      } finally {
        resetWhisperServerModule();
        clearWhisperServerOwnership(fake.port);
        fake.stop();
      }
    });

    it("records ownership when this process launches the server", async () => {
      let healthy = false;

      __setWhisperServerTestHooksForTests({
        findServerBinary: () => "/tmp/whisper-server",
        findModel: () => FAKE_MODEL,
        readHelpText: () => ({ helpText: "" }),
        findPortListenerPids: () => [],
        spawn: () => {
          healthy = true;
          return { pid: 55501, stderr: null, kill: () => {} };
        },
        isServerHealthy: async () => healthy,
        sleep: async () => {},
        startupTimeoutMs: 25,
      });

      try {
        await expect(ensureServer(18890)).resolves.toBe(18890);
        const owned = readWhisperServerOwnership(18890);
        expect(owned?.pid).toBe(55501);
        expect(owned?.owner_pid).toBe(process.pid);
        expect(owned?.model_path).toBe(FAKE_MODEL);
        expect(whisperServerLaunchRecord()?.adopted).toBeUndefined();

        // The launcher clears its own record when it stops the server.
        stopServer();
        expect(readWhisperServerOwnership(18890)).toBeNull();
      } finally {
        resetWhisperServerModule();
        clearWhisperServerOwnership(18890);
      }
    });

    it("resolves the listening pid of a port it can see", () => {
      const fake = startFakeHealthyServer();
      try {
        expect(portOwnerPids(fake.port)).toContain(process.pid);
      } finally {
        fake.stop();
      }
    });
  });

  describe("transcribeViaServer", () => {
    it("sends language and prompt fields to whisper-server inference", async () => {
      const originalFetch = globalThis.fetch;
      let inferenceForm: FormData | undefined;

      // @ts-ignore - test double
      globalThis.fetch = async (
        _url: string | URL | Request,
        init?: RequestInit,
      ) => {
        inferenceForm = init?.body as FormData;
        return new Response(JSON.stringify({ text: "שלום" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      };

      try {
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555, {
          language: "he",
          prompt: "פוש ברנץ Pull Request",
        });

        expect(text).toBe("שלום");
        expect(inferenceForm?.get("language")).toBe("he");
        expect(inferenceForm?.get("prompt")).toBe("פוש ברנץ Pull Request");
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it("normalizes timestamped-mode segment newlines from whisper-server JSON", async () => {
      const originalFetch = globalThis.fetch;

      // @ts-ignore - test double
      globalThis.fetch = async () =>
        new Response(
          JSON.stringify({
            text: " first segment\n second segment\n\n third segment\n",
          }),
          {
            status: 200,
            headers: { "content-type": "application/json" },
          },
        );

      try {
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555);

        expect(text).toBe("first segment second segment third segment");
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it("throws when whisper-server returns a JSON error payload with HTTP 200", async () => {
      const originalFetch = globalThis.fetch;

      // @ts-ignore - test double
      globalThis.fetch = async () =>
        new Response(JSON.stringify({ error: "FFmpeg conversion failed." }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });

      try {
        await expect(
          transcribeViaServer(new Uint8Array([1, 2]), 5555),
        ).rejects.toThrow("FFmpeg conversion failed");
      } finally {
        globalThis.fetch = originalFetch;
      }
    });

    it("retries once after an inference transport failure", async () => {
      const originalFetch = globalThis.fetch;
      let attempts = 0;
      let serverHealthy = false;

      // @ts-ignore - test double
      globalThis.fetch = async (url: string | URL | Request) => {
        if (String(url).endsWith("/health")) throw new Error("use test hook");

        attempts++;
        if (attempts === 1) {
          throw new Error("connection reset");
        }
        return new Response(JSON.stringify({ text: "after restart" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      };

      try {
        __setWhisperServerTestHooksForTests({
          findServerBinary: () => "/tmp/whisper-server",
          findModel: () => "/tmp/ggml-large-v3-turbo.bin",
          spawn: () => {
            serverHealthy = true;
            return {
              pid: 124,
              stderr: null,
              kill: () => {},
            };
          },
          isServerHealthy: async () => serverHealthy,
          sleep: async () => {},
          startupTimeoutMs: 25,
        });
        __resetWhisperServerStateForTests({
          proc: {
            kill: () => {
              serverHealthy = false;
            },
          } as any,
          port: 5555,
          pid: 123,
        });
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555);

        expect(text).toBe("after restart");
        expect(attempts).toBe(2);
      } finally {
        globalThis.fetch = originalFetch;
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });

    it("waits for an unhealthy managed process to exit before retrying inference", async () => {
      const originalFetch = globalThis.fetch;
      let attempts = 0;
      let exited = false;
      let serverHealthy = false;
      let resolveExit: (code: number) => void = () => {};

      // @ts-ignore - test double
      globalThis.fetch = async (url: string | URL | Request) => {
        if (String(url).endsWith("/health")) throw new Error("use test hook");

        attempts++;
        if (attempts === 1) {
          throw new Error("connection reset");
        }

        expect(exited).toBe(true);
        return new Response(JSON.stringify({ text: "after clean restart" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      };

      try {
        __setWhisperServerTestHooksForTests({
          findServerBinary: () => "/tmp/whisper-server",
          findModel: () => "/tmp/ggml-large-v3-turbo.bin",
          spawn: () => {
            expect(exited).toBe(true);
            serverHealthy = true;
            return {
              pid: 124,
              stderr: null,
              kill: () => {},
            };
          },
          isServerHealthy: async () => serverHealthy,
          sleep: async () => {},
          startupTimeoutMs: 25,
        });
        __resetWhisperServerStateForTests({
          proc: {
            kill: () => {
              setTimeout(() => resolveExit(0), 0);
            },
            exited: new Promise<number>((resolve) => {
              resolveExit = resolve;
            }).then((code) => {
              exited = true;
              serverHealthy = false;
              return code;
            }),
          } as any,
          port: 5555,
          pid: 123,
        });
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555);

        expect(text).toBe("after clean restart");
        expect(attempts).toBe(2);
      } finally {
        globalThis.fetch = originalFetch;
        __setWhisperServerTestHooksForTests({});
        __resetWhisperServerStateForTests(null);
      }
    });
  });
});
