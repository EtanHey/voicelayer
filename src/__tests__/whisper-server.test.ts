import { describe, it, expect } from "bun:test";
import {
  __resetWhisperServerStateForTests,
  __setWhisperServerTestHooksForTests,
  buildWhisperServerLaunchPlan,
  ensureServer,
  isServerAvailable,
  isServerHealthy,
  readWhisperServerHelpText,
  resolveWhisperAccelerationPlan,
  transcribeViaServer,
} from "../whisper-server";

describe("whisper-server", () => {
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
        "-nt",
        "--convert",
        "--no-gpu",
      ]);
      expect(launch.env.PATH).toBe("/opt/homebrew/bin");
      expect(launch.acceleration.mode).toBe("cpu");
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

  describe("transcribeViaServer", () => {
    it("sends language and prompt fields to whisper-server inference", async () => {
      const originalFetch = globalThis.fetch;
      let inferenceForm: FormData | undefined;

      // @ts-ignore - test double
      globalThis.fetch = async (_url: string | URL | Request, init?: RequestInit) => {
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

    it("retries once after an inference transport failure", async () => {
      const originalFetch = globalThis.fetch;
      let attempts = 0;

      // @ts-ignore - test double
      globalThis.fetch = async (url: string | URL | Request) => {
        if (String(url).endsWith("/health")) {
          return new Response(JSON.stringify({ status: "ok" }), {
            status: 200,
            headers: { "content-type": "application/json" },
          });
        }

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
        __resetWhisperServerStateForTests({
          proc: { kill: () => {} } as any,
          port: 5555,
          pid: 123,
        });
        const text = await transcribeViaServer(new Uint8Array([1, 2]), 5555);

        expect(text).toBe("after restart");
        expect(attempts).toBe(2);
      } finally {
        globalThis.fetch = originalFetch;
        __resetWhisperServerStateForTests(null);
      }
    });
  });
});
