import { expect, test } from "bun:test";
import { fallbackReasonFromBackend } from "../recording-provenance";
test("fallback reasons preserve future machine codes and explicitly unknown chains", () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  expect(fallbackReasonFromBackend("parakeet-resident+fallback-new-machine-reason->whisper.cpp")).toBe("new-machine-reason");
  expect(fallbackReasonFromBackend("parakeet-resident->whisper.cpp")).toBe("unknown");
});

test("completed provenance survives recognizer maintenance and changes only on transcription", async () => {
  const { noteRecognizerTranscription, noteRecognizerEffective, readRecognizerStatus } = await import("../recognizer-state");
  const backend = "parakeet-resident+fallback-provider-error->whisper.cpp";
  noteRecognizerTranscription(backend);
  noteRecognizerEffective("parakeet");
  expect(readRecognizerStatus().last_transcription_backend).toBe(backend);
  noteRecognizerTranscription("parakeet-resident");
  expect(readRecognizerStatus().last_transcription_backend).toBe("parakeet-resident");
});
