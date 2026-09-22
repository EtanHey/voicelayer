import { statSync } from "fs";
import { basename } from "path";
import {
  probeWhisperServerHealth,
  resolveWhisperModelPath,
  verifiedWhisperServerLaunchRecord,
} from "./whisper-server";
import {
  getWhisperPerformanceEffort,
  type WhisperPerformanceEffort,
} from "./whisper-performance";
import { resolveWhisperCliModelPath } from "./stt";

export type WhisperModelResidency = "loaded" | "not_loaded" | "unknown";

export interface WhisperModelStatus {
  configured_model: { name: string | null; size_bytes: number | null; installed: boolean };
  residency: WhisperModelResidency;
  active_model: string | null;
  configured_effort: WhisperPerformanceEffort;
  active_effort: WhisperPerformanceEffort | null;
}

interface ModelStatusEvidence {
  configuredPath: string | null;
  configuredSizeBytes: number | null;
  residentHealthy: boolean | null;
  launchRecord: { modelPath: string; performanceEffort: WhisperPerformanceEffort | null } | null;
  configuredEffort: WhisperPerformanceEffort;
}

function publicModelName(path: string | null): string | null {
  if (!path) return null;
  return basename(path).replace(/^ggml-/, "").replace(/\.bin$/, "") || null;
}

export function selectConfiguredModelPath(
  preference: string,
  residentPath: string | null,
  cliPath: string | null,
): string | null {
  if (preference === "wispr") return null;
  if (preference === "whisper") return cliPath;
  if (preference === "whisper-server" || preference === "resident") return residentPath;
  return residentPath ?? cliPath;
}

export function buildWhisperModelStatus(evidence: ModelStatusEvidence): WhisperModelStatus {
  const loaded = evidence.residentHealthy === true;
  return {
    configured_model: {
      name: publicModelName(evidence.configuredPath),
      size_bytes: evidence.configuredSizeBytes,
      installed: evidence.configuredSizeBytes !== null,
    },
    residency: evidence.residentHealthy === null
      ? "unknown"
      : loaded ? "loaded" : "not_loaded",
    active_model: loaded ? publicModelName(evidence.launchRecord?.modelPath ?? null) : null,
    configured_effort: evidence.configuredEffort,
    active_effort: loaded ? evidence.launchRecord?.performanceEffort ?? null : null,
  };
}

export async function readWhisperModelStatus(): Promise<WhisperModelStatus> {
  const preference = (process.env.QA_VOICE_STT_BACKEND ?? "auto").toLowerCase();
  const configuredPath = selectConfiguredModelPath(
    preference,
    resolveWhisperModelPath(),
    resolveWhisperCliModelPath(),
  );
  let configuredSizeBytes: number | null = null;
  if (configuredPath) {
    try {
      const stat = statSync(configuredPath);
      if (stat.isFile()) configuredSizeBytes = stat.size;
    } catch {}
  }
  let residentHealthy: boolean | null = preference === "wispr" ? null : false;
  let launchRecord: ModelStatusEvidence["launchRecord"] = null;
  if (preference !== "wispr" && preference !== "whisper") {
    const port = Number.parseInt(process.env.QA_VOICE_WHISPER_SERVER_PORT ?? "", 10) || 8178;
    residentHealthy = await probeWhisperServerHealth(port);
    if (residentHealthy === true) {
      launchRecord = verifiedWhisperServerLaunchRecord(port);
    }
  }
  return buildWhisperModelStatus({
    configuredPath,
    configuredSizeBytes,
    residentHealthy,
    launchRecord,
    configuredEffort: getWhisperPerformanceEffort(),
  });
}
