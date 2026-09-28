import { describe, expect, it } from "bun:test";
import { WhisperServerBackend } from "../stt";

function makeReviewWav(): Uint8Array {
  const samples = 95 * 16_000;
  const wav = new Uint8Array(44 + samples * 2);
  const view = new DataView(wav.buffer);
  const ascii = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i++) wav[offset + i] = value.charCodeAt(i);
  };
  ascii(0, "RIFF");
  view.setUint32(4, 36 + samples * 2, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, samples * 2, true);
  for (let i = 0; i < samples; i++) {
    view.setInt16(44 + i * 2, Math.round(2_000 * Math.sin((2 * Math.PI * 180 * i) / 16_000)), true);
  }
  return wav;
}

interface ReviewScript {
  chunk0: string;
  chunk1: string;
  promptedWitness: string;
  unpromptedWitness: string;
  fullWitness: string;
  extension?: string;
  later: string[];
}

async function replay(name: string, script: ReviewScript): Promise<string> {
  const wavPath = `/tmp/voicelayer-p02-${name}.wav`;
  await Bun.write(wavPath, makeReviewWav());
  let chunks = 0;
  let later = 0;
  const backend = new WhisperServerBackend({
    isServerAvailable: () => true,
    transcribeViaServer: async (data, options) => {
      const seconds = Math.round((data.length - 44) / 32_000);
      if (seconds >= 90) return script.fullWitness;
      if (seconds === 35) {
        return options?.prompt ? script.promptedWitness : script.unpromptedWitness;
      }
      if (seconds === 5) return script.extension ?? "";
      if (chunks++ === 0) return script.chunk0;
      if (chunks === 2) return script.chunk1;
      return script.later[later++] ?? "";
    },
  });
  return (await backend.transcribe(wavPath)).text;
}

const copies = (text: string, phrase: string): number => text.split(phrase).length - 1;

describe("P02 acoustic loop review regressions", () => {
  it("L1 repairs a hallucinated loop beside a genuine shared-prefix triple", async () => {
    const spoken = [
      "we should ship the build today",
      "we should ship the build tomorrow",
      "we should ship the build tonight",
    ];
    const genuine = `${spoken.join(". ")}.`;
    const loop = "the spoken status remains correct today";
    const text = await replay("l1", {
      chunk0: "intro reaches the boundary",
      chunk1: `the boundary ${genuine} ${Array(7).fill(loop).join(" ")} next topic begins here`,
      promptedWitness: `the boundary ${genuine} ${loop} next topic begins here`,
      unpromptedWitness: `the boundary ${genuine} ${loop} next topic begins here`,
      fullWitness: `intro reaches the boundary ${genuine} ${loop} next topic begins here and finishes`,
      extension: "next topic begins here",
      later: ["next topic begins here and finishes", "and finishes"],
    });
    for (const sentence of spoken) expect(text).toContain(sentence);
    expect(copies(text, loop)).toBe(1);
  });

  it("L8 repairs a separate loop while keeping each genuine five-word prefix", async () => {
    const prefix = "i want to check the";
    const genuine = `${prefix} logs first. ${prefix} tests next. ${prefix} build last.`;
    const loop = "the spoken status remains correct today";
    const text = await replay("l8", {
      chunk0: "intro reaches the boundary",
      chunk1: `the boundary ${genuine} ${Array(6).fill(loop).join(" ")} next topic begins here`,
      promptedWitness: `the boundary ${genuine} ${loop} next topic begins here`,
      unpromptedWitness: `the boundary ${genuine} ${loop} next topic begins here`,
      fullWitness: `intro reaches the boundary ${genuine} ${loop} next topic begins here and finishes`,
      extension: "next topic begins here",
      later: ["next topic begins here and finishes", "and finishes"],
    });
    expect(text).toContain(genuine);
    expect(copies(text, loop)).toBe(1);
  });

  it("L7 preserves fifteen intentional repetitions of a single word", async () => {
    const spoken = Array(15).fill("no").join(" ");
    const text = await replay("l7", {
      chunk0: "intro reaches the boundary",
      chunk1: `the boundary ${spoken} that is wrong next topic begins here`,
      promptedWitness: "the boundary no no no that is wrong next topic begins here",
      unpromptedWitness: "the boundary no no no that is wrong next topic begins here",
      fullWitness: "intro reaches the boundary no no no that is wrong next topic begins here and finishes",
      later: ["next topic begins here and finishes", "and finishes"],
    });
    expect(text.split(/\s+/).filter((word) => word === "no")).toHaveLength(15);
  });
});
