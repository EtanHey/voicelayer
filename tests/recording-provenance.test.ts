/**
 * Recording provenance — review-round regressions (PR #7 follow-up).
 *
 * These pin the four behaviours Macroscope flagged as wrong on #7:
 *  1. the subprocess probes never run on the archive hot path, and are bounded
 *     by a timeout when they do run (High, recording-provenance.ts:91);
 *  2. `whisper_cpp_version` describes the binary actually resolved for
 *     transcription, not whatever `brew list --versions whisper-cpp` says;
 *  4. non-whisper backends (Wispr, cancelled captures) get null whisper fields
 *     instead of plausible-but-false local-whisper metadata;
 *  5. `performance_effort` is the effort the resident server was *launched*
 *     with, not the current setting.
 *
 * The suite never shells out except in the one timeout test, which deliberately
 * spawns `sleep` to prove the bound is real rather than mocked.
 */
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

import { archiveVoiceBarRecording, createWavBuffer } from "../src/input";
import {
  __resetProvenanceProbeRunnersForTests,
  __resetWhisperBinaryResolversForTests,
  __runProbeCommandForTests,
  __setProvenanceProbeRunnersForTests,
  __setWhisperBinaryResolversForTests,
  buildRecordingProvenance,
  isWhisperBackend,
  normalizeWhisperBackend,
  primeMachineProvenance,
  primeRecordingProvenanceProbes,
  primeWhisperCppVersion,
  resetMachineProvenanceCacheForTests,
  resetWhisperCppVersionCacheForTests,
  whisperCppVersion,
  type RecordingProvenanceProbe,
} from "../src/recording-provenance";
import {
  __clearWhisperServerLaunchRecordForTests,
  __setWhisperServerLaunchRecordForTests,
} from "../src/whisper-server";

const READY_MACHINE: RecordingProvenanceProbe["machine"] = () => ({
  host: "test-mac",
  chip: "Apple M1 Pro",
  status: "ready",
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function resetProbeState(): void {
  resetMachineProvenanceCacheForTests();
  resetWhisperCppVersionCacheForTests();
  __resetProvenanceProbeRunnersForTests();
  __resetWhisperBinaryResolversForTests();
  __clearWhisperServerLaunchRecordForTests();
}

describe("provenance probes stay off the recording hot path", () => {
  let archiveRoot: string | undefined;
  let savedRecordingsDir: string | undefined;

  beforeEach(() => {
    savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
    archiveRoot = mkdtempSync(join(tmpdir(), "voicelayer-provenance-hotpath-"));
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
    resetProbeState();
  });

  afterEach(() => {
    if (archiveRoot) rmSync(archiveRoot, { recursive: true, force: true });
    archiveRoot = undefined;
    if (savedRecordingsDir === undefined) {
      delete process.env.QA_VOICE_RECORDINGS_DIR;
    } else {
      process.env.QA_VOICE_RECORDINGS_DIR = savedRecordingsDir;
    }
    resetProbeState();
  });

  function readProvenance(archivePath: string): Record<string, unknown> {
    const metadata = JSON.parse(
      readFileSync(join(archivePath, "metadata.json"), "utf8"),
    ) as Record<string, unknown>;
    return metadata.provenance as Record<string, unknown>;
  }

  function archive(transcript: string): string {
    const path = archiveVoiceBarRecording({
      audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
      transcript,
      createdAt: new Date("2026-09-05T07:08:09.123Z"),
      source: "voicebar",
      silenceMode: "standard",
      pushToEnd: false,
      durationMs: 900,
      backend: "whisper-server",
    });
    expect(path).toBeTruthy();
    return path!;
  }

  it("returns from the archive write without waiting for a slow probe", async () => {
    // Every probe takes far longer than an archive write is allowed to take.
    __setProvenanceProbeRunnersForTests({
      run: async (cmd) => {
        await sleep(400);
        return cmd[0] === "scutil" ? "Slow Mac" : "Apple M4 Max";
      },
      runMergingStderr: async () => {
        await sleep(400);
        return null;
      },
    });

    const started = Date.now();
    const archivePath = archive("hot path");
    const elapsed = Date.now() - started;

    expect(elapsed).toBeLessThan(100);
    const provenance = readProvenance(archivePath);
    expect(provenance.chip).toBe(null);
    expect(provenance.provenance_probe).toBe("pending");
    // The machine name still comes from the in-process os.hostname() lookup —
    // "pending" means the subprocess facts are missing, not that the record is.
    expect(typeof provenance.host).toBe("string");
    expect((provenance.host as string).length).toBeGreaterThan(0);

    // Once the probe the write kicked off resolves, later writes carry the
    // real facts without any recording ever having waited for them.
    await primeMachineProvenance();
    const second = readProvenance(archive("after probe"));
    expect(second.chip).toBe("Apple M4 Max");
    expect(second.host).toBe("Slow Mac");
  });

  it("bounds a wedged probe with a real timeout instead of hanging", async () => {
    const started = Date.now();
    const result = await __runProbeCommandForTests(["sleep", "5"], 150);
    const elapsed = Date.now() - started;

    expect(result).toBe(null);
    expect(elapsed).toBeLessThan(2_000);
  });
});

describe("whisper_cpp_version follows the resolved binary", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  it("reads the version out of the launched binary's Cellar path, with no brew call", async () => {
    let helpCalls = 0;
    __setProvenanceProbeRunnersForTests({
      runMergingStderr: async () => {
        helpCalls += 1;
        return "usage: whisper-server [options]";
      },
    });
    __setWhisperServerLaunchRecordForTests({
      binary: "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
      modelPath: "/fake/model.bin",
      args: [
        "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
        "-t",
        "4",
      ],
      performanceEffort: "accurate",
      accelerationMode: "metal",
      pid: 4242,
      startedAt: "2026-09-05T07:00:00.000Z",
    });

    // Hot-path read never waits: pending first, real value after the prime.
    expect(whisperCppVersion()).toEqual({ version: null, source: "pending" });
    expect(await primeWhisperCppVersion()).toEqual({
      version: "1.7.6",
      source: "cellar-path",
    });
    expect(whisperCppVersion()).toEqual({
      version: "1.7.6",
      source: "cellar-path",
    });
    expect(helpCalls).toBe(0);
  });

  it("falls back to the binary's own help output when the path carries no version", async () => {
    __setProvenanceProbeRunnersForTests({
      runMergingStderr: async () => "whisper-server v1.8.0-beta\nusage: ...",
    });
    __setWhisperServerLaunchRecordForTests({
      binary: "/usr/local/opt/custom/whisper-server",
      modelPath: "/fake/model.bin",
      args: ["/usr/local/opt/custom/whisper-server"],
      performanceEffort: "fast",
      accelerationMode: "cpu",
      pid: 7,
      startedAt: "2026-09-05T07:00:00.000Z",
    });

    expect(await primeWhisperCppVersion()).toEqual({
      version: "1.8.0",
      source: "binary-help",
    });
  });

  it("reports unresolved rather than guessing when the binary prints no version", async () => {
    __setProvenanceProbeRunnersForTests({
      runMergingStderr: async () => "usage: whisper-server [options]",
    });
    __setWhisperServerLaunchRecordForTests({
      binary: "/usr/local/opt/custom/whisper-server",
      modelPath: "/fake/model.bin",
      args: ["/usr/local/opt/custom/whisper-server"],
      performanceEffort: "fast",
      accelerationMode: "cpu",
      pid: 7,
      startedAt: "2026-09-05T07:00:00.000Z",
    });

    expect(await primeWhisperCppVersion()).toEqual({
      version: null,
      source: "unresolved",
    });
  });
});

describe("whisper fields are scoped to whisper backends", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  const WHISPER_PROBE: RecordingProvenanceProbe = {
    machine: READY_MACHINE,
    whisperCppVersion: () => ({ version: "1.7.4", source: "cellar-path" }),
    whisperModelPath: () => "/fake/.cache/whisper/ggml-large-v3-turbo.bin",
    whisperModelSha256: () => "b".repeat(64),
    whisperServerArgs: () => "-t 4 -bo 5 -bs 5",
    whisperServerProcess: () => ({
      pid: 4242,
      startedAt: "2026-09-05T07:00:00.000Z",
    }),
    performanceEffort: () => "accurate",
    polishMode: () => "shadow",
    appVersion: () => ({ version: "9.9.9", source: "package.json" }),
  };

  it("classifies only the local whisper backends as whisper", () => {
    expect(isWhisperBackend("whisper-server")).toBe(true);
    expect(isWhisperBackend("whisper.cpp")).toBe(true);
    expect(isWhisperBackend("wispr-flow")).toBe(false);
    expect(isWhisperBackend("not-transcribed")).toBe(false);
    expect(isWhisperBackend(null)).toBe(false);
  });

  it("leaves whisper fields null for a Wispr transcript", () => {
    const provenance = buildRecordingProvenance({
      backend: "wispr-flow",
      languageMode: "auto",
      polishStatus: "applied",
      probe: WHISPER_PROBE,
    });

    expect(provenance.whisper_model_path).toBe(null);
    expect(provenance.whisper_model_sha256).toBe(null);
    expect(provenance.whisper_cpp_version).toBe(null);
    expect(provenance.whisper_cpp_version_source).toBe("not-applicable");
    expect(provenance.whisper_server_args).toBe(null);
    expect(provenance.whisper_server_pid).toBe(null);
    expect(provenance.performance_effort).toBe(null);
    // Machine + polish + app facts are backend-independent and still recorded.
    expect(provenance.whisper_backend).toBe("wispr-flow");
    expect(provenance.chip).toBe("Apple M1 Pro");
    expect(provenance.polish_status).toBe("applied");
    expect(provenance.app_version).toBe("9.9.9");
  });

  it("keeps whisper fields for a whisper transcript", () => {
    const provenance = buildRecordingProvenance({
      backend: "whisper.cpp",
      languageMode: "auto",
      probe: WHISPER_PROBE,
    });

    expect(provenance.whisper_model_path).toBe(
      "/fake/.cache/whisper/ggml-large-v3-turbo.bin",
    );
    expect(provenance.whisper_cpp_version).toBe("1.7.4");
    expect(provenance.whisper_server_pid).toBe(4242);
    expect(provenance.performance_effort).toBe("accurate");
  });
});

describe("performance_effort describes the launched server", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  it("prefers the launch record's effort over the current setting", () => {
    const savedEffort = process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
    process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = "fast";
    try {
      __setWhisperServerLaunchRecordForTests({
        binary: "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
        modelPath: "/fake/model.bin",
        args: [
          "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
          "-bo",
          "5",
        ],
        // The server was launched under "accurate"; the setting has since
        // changed to "fast". The recording belongs to the launched server.
        performanceEffort: "accurate",
        accelerationMode: "metal",
        pid: 4242,
        startedAt: "2026-09-05T07:00:00.000Z",
      });

      const provenance = buildRecordingProvenance({
        backend: "whisper-server",
        languageMode: "auto",
        probe: { machine: READY_MACHINE },
      });
      expect(provenance.performance_effort).toBe("accurate");
      expect(provenance.whisper_server_pid).toBe(4242);
      expect(provenance.whisper_server_started_at).toBe(
        "2026-09-05T07:00:00.000Z",
      );
    } finally {
      if (savedEffort === undefined) {
        delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
      } else {
        process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = savedEffort;
      }
    }
  });

  it("falls back to the configured effort when no server is resident", () => {
    const savedEffort = process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
    process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = "fast";
    try {
      const provenance = buildRecordingProvenance({
        backend: "whisper.cpp",
        languageMode: "auto",
        probe: { machine: READY_MACHINE },
      });
      expect(provenance.performance_effort).toBe("fast");
      expect(provenance.whisper_server_pid).toBe(null);
    } finally {
      if (savedEffort === undefined) {
        delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
      } else {
        process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = savedEffort;
      }
    }
  });
});


// ---------------------------------------------------------------------------
// Review round 2 (PR #9)
// ---------------------------------------------------------------------------

describe("the prime path never blocks on binary resolution", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  it("settles well inside the bound even when both resolvers hang forever", async () => {
    // Stands in for the real hazard: `resolveBinary` spawns `which` and
    // `<candidate> --version` through Bun.spawnSync with no timeout, so a
    // wedged binary would hold the event loop through daemon startup.
    const neverResolves: Promise<string | null> = new Promise(() => {});
    __setWhisperBinaryResolversForTests({
      server: () => neverResolves,
      cli: () => neverResolves,
    });
    __setProvenanceProbeRunnersForTests({
      run: async (cmd) => (cmd[0] === "scutil" ? "test-mac" : "Apple M1 Pro"),
    });

    const started = Date.now();
    const settled = await Promise.race([
      primeRecordingProvenanceProbes().then(() => "settled" as const),
      // The prime must not be what loses this race.
      sleep(2_000).then(() => "timed-out" as const),
    ]);
    const elapsed = Date.now() - started;

    expect(settled).toBe("settled");
    expect(elapsed).toBeLessThan(2_000);
  });

  it("keeps the event loop responsive while a resolver is outstanding", async () => {
    let resolveLate: ((value: string | null) => void) | undefined;
    __setWhisperBinaryResolversForTests({
      server: () =>
        new Promise<string | null>((resolve) => {
          resolveLate = resolve;
        }),
      cli: async () => null,
    });

    let tickRan = false;
    const tick = new Promise<void>((resolve) =>
      setTimeout(() => {
        tickRan = true;
        resolve();
      }, 10),
    );
    const prime = primeWhisperCppVersion("server");
    await tick;

    // A blocking spawnSync inside the prime would have starved this timer.
    expect(tickRan).toBe(true);
    resolveLate?.(null);
    expect(await prime).toEqual({ version: null, source: "unresolved" });
  });
});

describe("decorated backend names are normalised, not rejected", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  const PROBE: RecordingProvenanceProbe = {
    machine: READY_MACHINE,
    whisperCppVersion: () => ({ version: "1.7.4", source: "cellar-path" }),
    whisperModelPath: () => "/fake/model.bin",
    whisperModelSha256: () => "c".repeat(64),
    whisperServerArgs: () => "-t 4",
    whisperServerProcess: () => ({ pid: 11, startedAt: "2026-09-05T07:00:00.000Z" }),
    performanceEffort: () => "accurate",
    polishMode: () => "shadow",
    appVersion: () => ({ version: "9.9.9", source: "package.json" }),
  };

  it("reduces a decorated name to the executable that produced the text", () => {
    // "+suffix" marks post-processing on the same backend.
    expect(normalizeWhisperBackend("whisper-server")).toBe("server");
    expect(normalizeWhisperBackend("whisper-server+chunks")).toBe("server");
    expect(normalizeWhisperBackend("whisper-server+chunks+witness+head")).toBe(
      "server",
    );
    expect(normalizeWhisperBackend("whisper-server+head+clean")).toBe("server");
    // "a->b" is a fallback chain: b produced the text.
    expect(normalizeWhisperBackend("whisper-server->whisper.cpp")).toBe("cli");
    expect(normalizeWhisperBackend("whisper-server->whisper.cpp+clean")).toBe(
      "cli",
    );
    expect(normalizeWhisperBackend("whisper.cpp")).toBe("cli");
    // Still not whisper.
    expect(normalizeWhisperBackend("wispr-flow")).toBe(null);
    expect(normalizeWhisperBackend("whisper-server->wispr-flow")).toBe(null);
    expect(normalizeWhisperBackend("not-transcribed")).toBe(null);
    expect(normalizeWhisperBackend(null)).toBe(null);
    expect(normalizeWhisperBackend("")).toBe(null);
  });

  it("populates whisper fields for whisper-server+chunks", () => {
    const provenance = buildRecordingProvenance({
      backend: "whisper-server+chunks",
      languageMode: "auto",
      probe: PROBE,
    });
    expect(isWhisperBackend("whisper-server+chunks")).toBe(true);
    expect(provenance.whisper_model_path).toBe("/fake/model.bin");
    expect(provenance.whisper_cpp_version).toBe("1.7.4");
    expect(provenance.whisper_cpp_version_source).toBe("cellar-path");
    expect(provenance.performance_effort).toBe("accurate");
  });

  it("populates whisper fields for whisper-server->whisper.cpp", () => {
    const provenance = buildRecordingProvenance({
      backend: "whisper-server->whisper.cpp",
      languageMode: "auto",
      probe: PROBE,
    });
    expect(isWhisperBackend("whisper-server->whisper.cpp")).toBe(true);
    expect(provenance.whisper_model_path).toBe("/fake/model.bin");
    expect(provenance.whisper_cpp_version).toBe("1.7.4");
  });
});

describe("a whisper.cpp transcript is attributed to the CLI, not the server", () => {
  beforeEach(resetProbeState);
  afterEach(resetProbeState);

  function residentServer(): void {
    __setWhisperServerLaunchRecordForTests({
      binary: "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
      modelPath: "/server/model.bin",
      args: [
        "/opt/homebrew/Cellar/whisper-cpp/1.7.6/bin/whisper-server",
        "-bo",
        "5",
      ],
      performanceEffort: "accurate",
      accelerationMode: "metal",
      pid: 4242,
      startedAt: "2026-09-05T07:00:00.000Z",
    });
  }

  it("probes the CLI binary, not the resident server's, for kind cli", async () => {
    residentServer();
    let cliResolved = 0;
    let serverResolved = 0;
    __setWhisperBinaryResolversForTests({
      cli: async () => {
        cliResolved += 1;
        return "/opt/homebrew/Cellar/whisper-cpp/1.7.2/bin/whisper-cli";
      },
      server: async () => {
        serverResolved += 1;
        return "/should/not/be/used/whisper-server";
      },
    });

    expect(await primeWhisperCppVersion("cli")).toEqual({
      version: "1.7.2",
      source: "cellar-path",
    });
    expect(cliResolved).toBe(1);
    // The launch record must not be consulted for a CLI transcript, and the
    // server resolver must not run for it either.
    expect(serverResolved).toBe(0);

    // The server kind still reads the launch record's binary — 1.7.6, not 1.7.2.
    expect(await primeWhisperCppVersion("server")).toEqual({
      version: "1.7.6",
      source: "cellar-path",
    });
    expect(serverResolved).toBe(0);
  });

  it("does not stamp the resident server's args, pid or effort on a CLI transcript", () => {
    residentServer();
    const savedEffort = process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
    process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = "fast";
    try {
      const provenance = buildRecordingProvenance({
        backend: "whisper-server->whisper.cpp",
        languageMode: "auto",
        probe: {
          machine: READY_MACHINE,
          whisperCppVersion: () => ({ version: "1.7.2", source: "cellar-path" }),
        },
      });

      expect(provenance.whisper_server_args).toBe(null);
      expect(provenance.whisper_server_pid).toBe(null);
      expect(provenance.whisper_server_started_at).toBe(null);
      // The CLI reads the effort setting per invocation, so "fast" is the truth
      // for it — not the "accurate" the resident server was launched under.
      expect(provenance.performance_effort).toBe("fast");
      expect(provenance.whisper_model_path).not.toBe("/server/model.bin");

      // The same recording via the server keeps all of them.
      const viaServer = buildRecordingProvenance({
        backend: "whisper-server+chunks",
        languageMode: "auto",
        probe: {
          machine: READY_MACHINE,
          whisperCppVersion: () => ({ version: "1.7.6", source: "cellar-path" }),
        },
      });
      expect(viaServer.whisper_server_args).toBe("-bo 5");
      expect(viaServer.whisper_server_pid).toBe(4242);
      expect(viaServer.performance_effort).toBe("accurate");
    } finally {
      if (savedEffort === undefined) {
        delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
      } else {
        process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = savedEffort;
      }
    }
  });
});
