/**
 * Standalone test: Connect to Wispr Flow WebSocket, send a few seconds of mic audio, see what comes back.
 * Usage: bun run packages/qa-voice/scripts/test-wispr-ws.ts
 */

const API_KEY = process.env.QA_VOICE_WISPR_KEY;
if (!API_KEY) {
  console.error("QA_VOICE_WISPR_KEY not set. Get your API key from Wispr Flow settings.");
  process.exit(1);
}
const WS_URL = `wss://platform-api.wisprflow.ai/api/v1/dash/ws?api_key=Bearer%20${API_KEY}`;

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHUNK_SIZE = SAMPLE_RATE * BYTES_PER_SAMPLE; // 1 second = 32000 bytes

console.log("=== Wispr Flow WebSocket Test ===");
console.log("Endpoint: wss://platform-api.wisprflow.ai/api/v1/dash/ws");
console.log("");

// Step 1: Test WebSocket connection
console.log("[1] Connecting to WebSocket...");
const ws = new WebSocket(WS_URL);

let packetIndex = 0;
let connected = false;

ws.addEventListener("open", () => {
  connected = true;
  console.log("[1] Connected! Sending auth...");
  ws.send(JSON.stringify({ type: "auth", language: ["en"] }));
  console.log("[1] Auth sent. Starting mic recording...");

  // Step 2: Start mic recording
  startRecording();
});

ws.addEventListener("message", (event) => {
  console.log("[WS MSG]", String(event.data));
});

ws.addEventListener("error", (event) => {
  console.log("[WS ERR]", event);
});

ws.addEventListener("close", (event) => {
  console.log("[WS CLOSE] code:", event.code, "reason:", event.reason);
});

function startRecording() {
  const recorder = Bun.spawn(
    ["rec", "-r", String(SAMPLE_RATE), "-c", "1", "-b", "16", "-e", "signed", "-t", "raw", "-q", "-"],
    { stdout: "pipe", stderr: "ignore" }
  );

  console.log("[2] Recorder started, PID:", recorder.pid);
  console.log("[2] Speak now! Recording for 5 seconds...");

  if (!recorder.stdout) {
    console.log("[2] ERROR: No stdout from recorder!");
    process.exit(1);
  }

  const reader = (recorder.stdout as ReadableStream<Uint8Array>).getReader();
  let audioBuffer = new Uint8Array(0);
  let chunksSent = 0;

  const processAudio = async () => {
    const startTime = Date.now();

    while (Date.now() - startTime < 5000) {
      const { value, done } = await reader.read();
      if (done) break;

      // Append to buffer
      const combined = new Uint8Array(audioBuffer.length + value.length);
      combined.set(audioBuffer);
      combined.set(value, audioBuffer.length);
      audioBuffer = combined;

      // Process complete 1-second chunks
      while (audioBuffer.length >= CHUNK_SIZE) {
        const chunk = audioBuffer.slice(0, CHUNK_SIZE);
        audioBuffer = audioBuffer.slice(CHUNK_SIZE);

        // Calculate RMS
        const view = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
        let sumSquares = 0;
        const numSamples = chunk.byteLength / BYTES_PER_SAMPLE;
        for (let i = 0; i < numSamples; i++) {
          const sample = view.getInt16(i * BYTES_PER_SAMPLE, true);
          sumSquares += sample * sample;
        }
        const rms = Math.sqrt(sumSquares / numSamples);

        if (ws.readyState === WebSocket.OPEN) {
          const b64 = Buffer.from(chunk).toString("base64");
          ws.send(JSON.stringify({
            type: "append",
            position: packetIndex++,
            audio_packets: {
              packets: [b64],
              volumes: [rms],
              packet_duration: 1.0,
              audio_encoding: "wav",
              byte_encoding: "base64",
            },
          }));
          chunksSent++;
          console.log(`[3] Sent chunk ${chunksSent} (RMS: ${rms.toFixed(0)}, ${chunk.byteLength} bytes)`);
        } else {
          console.log("[3] WebSocket not open, can't send chunk");
        }
      }
    }

    console.log(`[4] Done recording. Sent ${chunksSent} chunks. Sending commit...`);

    // Send commit
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "commit", total_packets: packetIndex }));
      console.log("[4] Commit sent. Waiting 5s for response...");
    }

    // Kill recorder
    recorder.kill();

    // Wait for response
    setTimeout(() => {
      console.log("\n[5] Test complete. Closing.");
      ws.close();
      process.exit(0);
    }, 5000);
  };

  processAudio().catch((err) => {
    console.error("[ERR]", err);
    recorder.kill();
    process.exit(1);
  });
}

// Timeout safety
setTimeout(() => {
  if (!connected) {
    console.log("[TIMEOUT] WebSocket never connected after 15s");
  } else {
    console.log("[TIMEOUT] 15s total timeout reached");
  }
  process.exit(1);
}, 15000);
