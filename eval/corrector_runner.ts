import { correctTranscriptionText, type STTCorrectorMode } from "../src/stt-corrector";

interface CorrectorRequest {
  backend: STTCorrectorMode;
  items: Array<{
    id: string;
    text: string;
  }>;
}

const body = await new Response(Bun.stdin.stream()).text();
const request = JSON.parse(body) as CorrectorRequest;

if (request.backend !== "identity" && request.backend !== "rules") {
  throw new Error(`Unsupported corrector backend: ${request.backend}`);
}

correctTranscriptionText("brain layer", { mode: request.backend });

const results = request.items.map((item) => {
  const result = correctTranscriptionText(item.text, { mode: request.backend });
  return {
    id: item.id,
    text: result.text,
    latency_ms: result.latencyMs,
    changed: result.changed,
    mode: result.mode,
  };
});

process.stdout.write(JSON.stringify({ results }));
