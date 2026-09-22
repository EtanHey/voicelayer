export interface DictationReceiptMetadata {
  audio_duration_ms: number;
  processing_duration_ms: number;
}

export interface DictationReceiptTiming {
  audioDurationMs?: number;
  processingStartedAtMs?: number;
  finalTranscriptReadyAtMs?: number;
}

export function buildDictationReceipt(
  timing: DictationReceiptTiming,
): DictationReceiptMetadata | undefined {
  const {
    audioDurationMs,
    processingStartedAtMs,
    finalTranscriptReadyAtMs,
  } = timing;
  if (
    !Number.isFinite(audioDurationMs) ||
    !Number.isFinite(processingStartedAtMs) ||
    !Number.isFinite(finalTranscriptReadyAtMs)
  ) {
    return undefined;
  }

  const processingDurationMs = finalTranscriptReadyAtMs! - processingStartedAtMs!;
  if (!Number.isFinite(processingDurationMs)) return undefined;

  const roundedAudioDurationMs = Math.round(audioDurationMs!);
  const roundedProcessingDurationMs = Math.round(processingDurationMs);
  if (
    !Number.isFinite(roundedAudioDurationMs) ||
    !Number.isFinite(roundedProcessingDurationMs) ||
    roundedAudioDurationMs <= 0 ||
    roundedProcessingDurationMs <= 0
  ) {
    return undefined;
  }

  return {
    audio_duration_ms: roundedAudioDurationMs,
    processing_duration_ms: roundedProcessingDurationMs,
  };
}
