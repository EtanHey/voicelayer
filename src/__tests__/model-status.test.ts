import { describe, expect, it } from "bun:test";
import { buildWhisperModelStatus, selectConfiguredModelPath } from "../model-status";

describe("whisper model status", () => {
  it("uses the CLI model search result when that backend is configured", () => {
    expect(selectConfiguredModelPath("whisper", null, "/models/ggml-small.en.bin"))
      .toBe("/models/ggml-small.en.bin");
  });
  it("reports configured and proven active identities separately", () => {
    expect(buildWhisperModelStatus({
      configuredPath: "/private/user/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 1_617_000_000,
      residentHealthy: true,
      launchRecord: {
        modelPath: "/another/private/path/ggml-base.en.bin",
        performanceEffort: "balanced",
      },
      configuredEffort: "accurate",
    })).toEqual({
      configured_model: { name: "large-v3-turbo", size_bytes: 1_617_000_000, installed: true },
      residency: "loaded",
      active_model: "base.en",
      configured_effort: "accurate",
      active_effort: "balanced",
    });
  });
  it("does not guess active identity for a healthy server without provenance", () => {
    const status = buildWhisperModelStatus({
      configuredPath: "/models/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 10,
      residentHealthy: true,
      launchRecord: null,
      configuredEffort: "fast",
    });
    expect(status.residency).toBe("loaded");
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });
  it("keeps proven adopted model identity when its effort is unknown", () => {
    const status = buildWhisperModelStatus({
      configuredPath: "/models/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 10,
      residentHealthy: true,
      launchRecord: { modelPath: "/models/ggml-base.en.bin", performanceEffort: null },
      configuredEffort: "accurate",
    });
    expect(status.active_model).toBe("base.en");
    expect(status.active_effort).toBeNull();
  });
  it("keeps unavailable residency unknown", () => {
    const status = buildWhisperModelStatus({
      configuredPath: null,
      configuredSizeBytes: null,
      residentHealthy: null,
      launchRecord: null,
      configuredEffort: "accurate",
    });
    expect(status.configured_model).toEqual({ name: null, size_bytes: null, installed: false });
    expect(status.residency).toBe("unknown");
  });
});
