/** Explicit private-archive eval. Run with nice -n 15 bun run scripts/dictation-loss-eval.ts ...
 * --archive DIR --start ID --output DIR (must be gitignored docs.local)
 * --python PATH --parakeet-model DIR --whisper-model FILE --polish-model DIR
 * Optional --vocabulary FILE --processing-settings FILE. No downloads or live engines.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { join, resolve, sep } from "node:path";
import { getPriority, homedir } from "node:os";
import { connect, createServer } from "node:net";
import { createHash } from "node:crypto";
import { z } from "zod";
import { alignLoss, lossWords, stageEdges, LOSS_CLASSES } from "../src/dictation-loss-eval";
import { compareTranscriptToReference } from "../src/stt-decode-benchmark";

const Metadata = z.object({ transcription_status: z.string().optional(), backend: z.string().optional(),
  duration_ms: z.number().optional(), transcribed_duration_ms: z.number().optional(),
  last_stt_gate_removal: z.unknown().optional() }).passthrough();
const Native = z.object({ text: z.string(), last_token_end_s: z.number().nullable(), input_frames: z.number(),
  covered_frames: z.number(), complete: z.boolean(), raw_token_times: z.array(z.unknown()).optional() }).passthrough();
const Reply = z.object({ ok: z.boolean(), id: z.number(), attempt: Native.optional() }).passthrough();
const PersistedState = z.object({ state: z.enum(["idle", "recording", "transcribing"]), pid: z.number().int().positive(), updated_at: z.string() });

/** Native socket has no health request. Check connectivity passively, then its daemon's published state. */
export async function idleState(socketPath = "/tmp/voicelayer.sock", statePath = join(homedir(), ".local/state/voicelayer/recording-state.json")): Promise<void> {
  await new Promise<void>((done, fail) => {
    const socket = connect(socketPath), timer = setTimeout(() => finish(new Error("Live socket unavailable; refusing heavy work")), 4000);
    function finish(error?: Error) { clearTimeout(timer); socket.destroy(); error ? fail(error) : done(); }
    socket.once("connect", () => finish());
    socket.once("error", () => finish(new Error("Live socket unavailable; refusing heavy work")));
  });
  const state = PersistedState.parse(JSON.parse(readFileSync(statePath, "utf8")));
  process.kill(state.pid, 0); // Read-only owner liveness; no signal is sent.
  if (state.state !== "idle") throw new Error(`BUSY: ${state.state}; resume later`);
}
function args(argv: string[]) {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i], value = argv[i + 1];
    if (!key?.startsWith("--") || !value || value.startsWith("--")) throw new Error("Expected --flag value pairs; see script header");
    if (!["archive", "start", "output", "python", "parakeet-model", "whisper-model", "polish-model", "vocabulary", "processing-settings", "attempts", "journal"].includes(key.slice(2))) throw new Error(`Unknown option ${key}`);
    values.set(key.slice(2), value);
  }
  const required = (key: string) => { const v = values.get(key); if (!v) throw new Error(`Missing --${key}`); return v; };
  return { archive: realpathSync(required("archive")), start: required("start"), output: resolve(required("output")),
    python: resolve(required("python")), parakeet: realpathSync(required("parakeet-model")),
    whisper: realpathSync(required("whisper-model")), polish: realpathSync(required("polish-model")),
    vocabulary: values.get("vocabulary"), settings: values.get("processing-settings"), attempts: values.get("attempts"), journal: values.get("journal") };
}
function save(path: string, value: unknown) { writeFileSync(path, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 }); }
async function main() {
  const options = args(process.argv.slice(2));
  const decodeIdentity = createHash("sha256").update(JSON.stringify({ version: 1, python: options.python, parakeet: options.parakeet,
    whisper: options.whisper, assets: [options.whisper, join(options.parakeet, "model.safetensors"), join(options.parakeet, "config.json")]
      .map(path => ({ path, bytes: statSync(path).size, mtimeMs: statSync(path).mtimeMs })), worker: readFileSync(join(import.meta.dir, "../src/parakeet-worker.py"), "utf8"),
    reference: "whisper.cpp-large-v3-turbo-auto-default-best5-beam5-no-prompt" })).digest("hex");
  if (getPriority() < 15) throw new Error("Run with nice -n 15 (children inherit low priority)");
  mkdirSync(options.output, { recursive: true, mode: 0o700 });
  const output = realpathSync(options.output);
  if (!output.split(sep).includes("docs.local") || output.startsWith(options.archive + sep)) throw new Error("Output must be private docs.local outside the archive");
  const ignored = Bun.spawnSync(["git", "-C", output, "check-ignore", "-q", "."], { env: process.env });
  if (ignored.exitCode !== 0) throw new Error("Output is not gitignored");
  const runtime = join(output, ".runtime"); mkdirSync(runtime, { recursive: true, mode: 0o700 });
  Object.assign(process.env, {
    VOICELAYER_TEST_ISOLATED: "1", VOICELAYER_TEST_RUN_ROOT: runtime,
    VOICELAYER_TMP_ROOT: runtime, VOICELAYER_STATE_DIR: runtime, VOICELAYER_CONTROL_LAYER_BASE: runtime,
    VOICELAYER_SOCKET_PATH: join(runtime, "unused.sock"), VOICELAYER_MCP_SOCKET_PATH: join(runtime, "unused-mcp.sock"),
    QA_VOICE_MCP_PID_PATH: join(runtime, "mcp.pid"), QA_VOICE_RECORDINGS_DIR: join(runtime, "unused-recordings"),
    NO_PROXY: "127.0.0.1,localhost", QA_VOICE_STT_POLISH_SOCKET: join(runtime, "unused-polish.sock"), QA_VOICE_STT_POLISH_LOG_PATH: join(runtime, "polish.jsonl"),
    QA_VOICE_STT_VOCABULARY_PATH: options.vocabulary ?? "", QA_VOICE_STT_COMMANDS_DIR: join(runtime, "commands"),
    QA_VOICE_WHISPER_MODEL: options.whisper, QA_VOICE_WHISPER_PERFORMANCE_EFFORT: "accurate",
    QA_VOICE_WHISPER_LANG: "auto", VOICELAYER_STT_OUTRO_GATE: "1", TMPDIR: runtime,
    VOICELAYER_PROCESSING_SETTINGS_PATH: options.settings ?? join(runtime, "settings.json"),
    VOICELAYER_UPDATE_GATE_PATH: join(runtime, "gate.json"),
    HF_HUB_OFFLINE: "1", TRANSFORMERS_OFFLINE: "1", TOKENIZERS_PARALLELISM: "false",
    XDG_CACHE_HOME: resolve(".build.noindex/dictation-loss-cache"),
  });
  // Import only after isolation: input.ts freezes some paths at module load.
  const { finalizeTranscriptionText, createWavBuffer } = await import("../src/input");
  const { polishTranscriptionText } = await import("../src/stt-polish");
  const { applyCoherentParagraphFallback } = await import("../src/stt-coherent-paragraphs");
  const { processingEnv } = await import("../src/processing-settings");
  const { WhisperCppBackend } = await import("../src/stt");
  const { stripHallucinatedCaption } = await import("../src/stt-caption-gate");
  const { measureWavWindows, measureSpan, stripHallucinatedOutro, isCjkHallucinationCandidate } = await import("../src/stt-outro-gate");
  const { createVADSession, VAD_CHUNK_SAMPLES } = await import("../src/vad");
  const { parseWavAudioInfo } = await import("../src/stt-pause-map");
  const config = processingEnv();
  async function speechIn(wav: Uint8Array) {
    const info = parseWavAudioInfo(wav); if (!info) throw new Error("Invalid VAD WAV");
    const session = await createVADSession();
    let speech = false;
    for (let offset = 0; offset < info.dataSize; offset += VAD_CHUNK_SAMPLES * 2) {
      const chunk = new Uint8Array(VAD_CHUNK_SAMPLES * 2);
      chunk.set(wav.subarray(info.dataOffset + offset, info.dataOffset + Math.min(offset + chunk.length, info.dataSize)));
      const probability = await session.process(chunk);
      if (!Number.isFinite(probability) || probability < 0 || probability > 1) throw new Error("Invalid VAD probability");
      speech ||= probability >= 0.3;
    }
    return speech;
  }
  const takes = readdirSync(options.archive, { withFileTypes: true }).filter(d => d.isDirectory()).flatMap(d =>
    readdirSync(join(options.archive, d.name), { withFileTypes: true }).filter(t => t.isDirectory() && t.name >= options.start)
      .map(t => ({ id: t.name, dir: join(options.archive, d.name, t.name) }))).sort((a, b) => a.id.localeCompare(b.id));
  if (!takes.some(t => t.id === options.start)) throw new Error("Start id not found; refusing partial scope");
  const originals = options.attempts ? readdirSync(options.attempts).filter(p => p.endsWith(".json")).map(p => ({
    path: join(options.attempts!, p), value: z.object({ inputSha256: z.string().nullable().optional(), stage: z.string().optional(),
      parakeet: Native.nullable().optional(), whisper: z.object({ text: z.string() }).passthrough().nullable().optional(),
      deliveryText: z.string().optional() }).passthrough().parse(JSON.parse(readFileSync(join(options.attempts!, p), "utf8"))) })) : [];
  const { Database } = await import("bun:sqlite");
  const journal = options.journal ? new Database(options.journal, { readonly: true }) : null;
  const events = journal?.query("SELECT ts, payload_json FROM events WHERE type='transcription.polish' AND ts >= ? ORDER BY ts").all(options.start.slice(0,10) + "T" + options.start.slice(11,19).replaceAll("-", ":")) ?? [];
  journal?.close();
  const results = [];
  for (const take of takes) {
    const metadata = Metadata.parse(JSON.parse(readFileSync(join(take.dir, "metadata.json"), "utf8")));
    const finalPath = join(take.dir, "voicelayer-transcript.txt"), audio = join(take.dir, "audio.wav");
    if (metadata.transcription_status !== "transcribed" || !existsSync(finalPath) || !existsSync(audio)) {
      results.push({ id: take.id, skipped: metadata.transcription_status ?? "no transcription status", metadata }); continue;
    }
    const archived = readFileSync(finalPath, "utf8"), hash = createHash("sha256").update(readFileSync(audio)).digest("hex");
    async function nativeDecode() {
      await idleState();
      const proc = Bun.spawn(["nice", "-n", "15", options.python, "-u", join(import.meta.dir, "../src/parakeet-worker.py"),
        "--model", options.parakeet, "--parent-pid", String(process.pid)], { env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
      const timer = setTimeout(() => proc.kill("SIGKILL"), 300_000);
      let native = null, nativeError = null;
      try {
        proc.stdin.write(JSON.stringify({ id: 1, op: "transcribe", audio_path: audio }) + "\n"); await proc.stdin.flush(); proc.stdin.end();
        const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
        writeFileSync(join(output, `${take.id}.parakeet.stderr.log`), stderr, { mode: 0o600 });
        if (!stdout.trim()) throw new Error(`Parakeet returned no reply; exit ${code}; see private stderr log`);
        const reply = Reply.parse(JSON.parse(stdout.trim()));
        native = reply.ok ? Native.parse(reply) : reply.attempt ?? null;
        if (!reply.ok || code !== 0) nativeError = `Parakeet ${String(reply.code ?? "returned failure")}; exit ${code}`;
      } catch (error) { nativeError = error instanceof Error ? error.message : "Parakeet failed"; }
      finally { clearTimeout(timer); if (proc.exitCode === null) proc.kill("SIGKILL"); await proc.exited; }
      return { native, nativeError };
    }
    const cachePath = join(output, `${take.id}.decode.json`);
    let decoded;
    if (existsSync(cachePath)) {
      decoded = z.object({ decodeIdentity: z.literal(decodeIdentity), hash: z.literal(hash), native: Native.nullable(), nativeError: z.string().nullable(),
        reference: z.string(), gated: z.string(), outro: z.string(), segments: z.array(z.object({ text: z.string(), startS: z.number(), endS: z.number() })) }).parse(JSON.parse(readFileSync(cachePath, "utf8")));
    } else {
      await idleState();
      let reference = "", outro = "";
      let segments: { text: string; startS: number; endS: number }[] = [];
      const backend = new WhisperCppBackend({ noVocabularyPrompt: true, captionGate: async (text, wav, gateOptions) => {
        segments = gateOptions?.segments ?? []; reference = gateOptions?.segmentsText ?? ""; outro = text;
        return stripHallucinatedCaption(text, wav, gateOptions);
      } });
      const result = await backend.transcribe(audio);
      if (!reference) throw new Error("Whisper did not expose ungated JSON; refusing false raw baseline");
      decoded = { decodeIdentity, hash, ...await nativeDecode(), reference, gated: result.text, outro, segments };
      save(cachePath, decoded);
    }
    if (decoded.decodeIdentity && decoded.decodeIdentity !== decodeIdentity) throw new Error("Decode cache configuration changed; use a fresh private output directory");
    decoded.decodeIdentity = decodeIdentity;
    const wav = new Uint8Array(readFileSync(audio)), windows = measureWavWindows(wav);
    await idleState();
    const info = parseWavAudioInfo(wav); if (!info) throw new Error("Invalid archive WAV");
    let outroReplay = stripHallucinatedOutro(decoded.reference, wav, { segments: decoded.segments, segmentsText: decoded.reference });
    if (outroReplay.removed.length && !isCjkHallucinationCandidate(decoded.reference)) for (const removal of outroReplay.removed) {
      const start = Math.max(0, removal.startS - 0.3), finish = removal.endS + 0.15;
      const region = createWavBuffer(wav.subarray(info.dataOffset + Math.floor(start * 16000) * 2,
        info.dataOffset + Math.min(info.dataSize, Math.ceil(finish * 16000) * 2)));
      if (await speechIn(region)) { outroReplay = { ...outroReplay, text: decoded.reference, removed: [], reason: "energy-present" }; break; }
    }
    decoded.outro = outroReplay.text;
    const captionReplay = await stripHallucinatedCaption(decoded.outro, wav, { segments: decoded.segments, segmentsText: decoded.reference });
    decoded.gated = captionReplay.text; save(cachePath, decoded);
    const end = decoded.native?.last_token_end_s;
    const duration = decoded.native ? decoded.native.input_frames / 16000 : 0;
    const tailEnergy = windows && end != null && end < duration ? measureSpan(windows, end, duration) : null;
    // Candidate seams only: segment starts near known 28s chunk advances, never interpolated word times.
    let referenceWords = 0;
    const seamCandidates = decoded.segments.flatMap(segment => {
      const index = referenceWords; referenceWords += lossWords(segment.text).length;
      const boundaryS = Math.round(segment.startS / 28) * 28;
      return boundaryS > 0 && Math.abs(segment.startS - boundaryS) <= 2
        ? [{ index, segmentStartS: segment.startS, boundaryS, evidence: "segment-start heuristic" }] : [];
    });
    const fallback = metadata.backend?.includes("fallback") ?? false;
    const raw = decoded.native?.text ?? decoded.reference;
    const matched = originals.filter(o => o.value.inputSha256 === hash);
    const originalFallback = matched.find(o => o.value.stage === "fallback-terminal")?.value.whisper?.text;
    results.push({ id: take.id, metadata, archived, ...decoded, tailEnergy, tailStartS: end, audioDurationS: duration,
      originalBoundaries: matched,
      rawKind: decoded.native ? "same-backend re-decode; original raw unavailable" : "reference-raw stand-in",
      pipelineInput: fallback ? originalFallback ? "hash-matched original post-gate Whisper" : "independent Whisper stand-in for historical fallback" : "same-backend re-decode",
      inputText: fallback ? originalFallback ?? decoded.gated : raw,
      referenceComparison: { ...compareTranscriptToReference(archived, decoded.reference), source: "independent-reference-hypothesis" },
      seamCandidates, referenceVsFinal: alignLoss(decoded.reference, archived, seamCandidates.map(s => s.index)), rawVsFinal: alignLoss(raw, archived),
      gateEdges: stageEdges([{ name: "reference-raw", text: decoded.reference }, { name: "outro", text: decoded.outro }, { name: "caption", text: decoded.gated }]),
    });
    console.log(`Decoded ${take.id}`);
  }
  for (const take of results) if ("inputText" in take) {
    const dictionary = finalizeTranscriptionText(take.inputText, config);
    Object.assign(take, { deterministicReplay: stageEdges([{ name: "backend-output", text: take.inputText },
      { name: "dictionary_rules", text: dictionary }, { name: "paragraph-only", text: applyCoherentParagraphFallback(dictionary) }]) });
  }
  save(join(output, "eval.json"), { base: "870b16170907bf49862027e240771059d9bd8afe", options, events, results, replay: "pending" });
  // A new server binds an OS-assigned private port; never adopt or call a resident endpoint.
  await idleState();
  const reservation = createServer(); await new Promise<void>(r => reservation.listen(0, "127.0.0.1", r));
  const address = reservation.address(); if (!address || typeof address === "string") throw new Error("No private port");
  const port = address.port; await new Promise<void>((r, reject) => reservation.close(e => e ? reject(e) : r()));
  const server = Bun.spawn(["nice", "-n", "15", "mlx_lm.server", "--model", options.polish, "--host", "127.0.0.1", "--port", String(port)],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  const ownsListener = () => server.exitCode === null && Bun.spawnSync(["lsof", "-nP", "-a", "-p", String(server.pid),
    "-iTCP:" + port, "-sTCP:LISTEN"], { env: process.env, stdout: "pipe", stderr: "pipe" }).exitCode === 0;
  const drains = Promise.all([new Response(server.stdout).text(), new Response(server.stderr).text()]);
  let polishBlocker: string | null = null;
  try {
    const endpoint = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let count = 0; count < 120 && server.exitCode === null; count++) {
      try { ready = ownsListener() && (await fetch(endpoint + "/v1/models", { signal: AbortSignal.timeout(1000) })).ok; } catch {}
      if (ready) break; await Bun.sleep(500);
    }
    if (!ready) throw new Error(`Isolated polish unavailable; exit ${server.exitCode}`);
    for (const take of results) {
      if (!("inputText" in take)) continue;
      const cleaned = finalizeTranscriptionText(take.inputText, config), replays = [];
      for (let repeat = 0; repeat < 2; repeat++) {
        await idleState();
        if (!ownsListener()) throw new Error("Lost isolated polish listener ownership");
        const polish = await polishTranscriptionText({ rawText: take.inputText, cleanedText: cleaned, surface: "dictation",
          env: { ...config, QA_VOICE_STT_POLISH_ENDPOINT: endpoint + "/v1/chat/completions", QA_VOICE_STT_POLISH_MODEL: options.polish } });
        const paragraphs = applyCoherentParagraphFallback(polish.text);
        replays.push({ status: polish.status, reason: polish.reason, reproducesArchive: paragraphs === take.archived,
          stages: [{ name: "backend-output", text: take.inputText }, { name: "dictionary_rules", text: cleaned },
            { name: "polish", text: polish.text }, { name: "paragraphs", text: paragraphs }],
          edges: stageEdges([{ name: "backend-output", text: take.inputText }, { name: "dictionary_rules", text: cleaned },
            { name: "polish", text: polish.text }, { name: "paragraphs", text: paragraphs }]) });
      }
      Object.assign(take, { replays });
    }
  } catch (error) { polishBlocker = error instanceof Error ? error.message : "Polish failed"; }
  finally { server.kill("SIGTERM"); const timer = setTimeout(() => server.kill("SIGKILL"), 3000); await server.exited; clearTimeout(timer); await drains; }
  const report = { generatedAt: new Date().toISOString(), base: "870b16170907bf49862027e240771059d9bd8afe", options, polishBlocker, events, results };
  save(join(output, "eval.json"), report);
  const lines = ["# Dictation loss eval", "", "Status: measurement only; original raw exists only for hash-matched retained fallback boundaries. No human-verified reference. Decode disagreements are candidates.",
    "", `Base: ${report.base}. Snapshot: ${report.generatedAt}. Independent reference: large-v3-turbo, accurate, no vocabulary prompt.`,
    "", "Gates precede dictionary/polish. Reference gate edges are counterfactual on ordinary Parakeet takes. Fallback uses hash-matched original post-gate Whisper when available; otherwise a labelled reference stand-in.",
    "Idle guard: native socket connectivity plus the daemon-published recording-state file and owner PID liveness; native socket has no health reply.",
    "Energy after the last token is an acoustic heuristic, not proof of speech. Seam labels are candidates at reference segment starts within 2s of 28s chunk advances; no Parakeet word positions are inferred from token count.",
    "Polish is replayed twice; paragraph replay uses the text-only fallback (original pause-map context unavailable). Token deletions can be alias joins or command formatting; they are not all speech losses.", "", `Polish blocker: ${polishBlocker ?? "none"}.`, "",
    "| Take | Status/backend | Reference vs final edits | Raw vs final edits | Replay archive matches |", "|---|---|---:|---:|---|",
    ...results.map(t => "skipped" in t ? `| ${t.id} | SKIP: ${t.skipped} | — | — | — |` : `| ${t.id} | ${t.metadata.backend} | ${t.referenceVsFinal.length} | ${t.rawVsFinal.length} | ${"replays" in t ? JSON.stringify(t.replays).match(/"reproducesArchive":true/g)?.length ?? 0 : 0}/2 |`), "",
    "## Candidate class totals (multi-label; substitutions separated from deletions)", "", "| Comparison | Class | Deleted | Substituted |", "|---|---|---:|---:|"];
  const comparisons = new Map<string, ReturnType<typeof alignLoss>>();
  for (const take of results) if ("rawVsFinal" in take) {
    for (const [label, edits] of [["raw → archived (historical stage unknown)", take.rawVsFinal], ["reference → archived (decoder disagreement)", take.referenceVsFinal]] as const) comparisons.set(label, [...(comparisons.get(label) ?? []), ...edits]);
    const replays = "replays" in take ? z.array(z.object({ edges: z.array(z.object({ from: z.string(), to: z.string(), edits: z.array(z.custom<ReturnType<typeof alignLoss>[number]>()) })) })).parse(take.replays) : [];
    for (const edge of [...take.gateEdges, ...(replays[0]?.edges ?? [])]) {
      const label = `replay ${edge.from} → ${edge.to}`; comparisons.set(label, [...(comparisons.get(label) ?? []), ...edge.edits]);
    }
  }
  for (const [label, edits] of comparisons) for (const cls of LOSS_CLASSES) lines.push(`| ${label} | ${cls} | ${edits.filter(e => e.kind === "delete" && e.tags.includes(cls)).length} | ${edits.filter(e => e.kind === "substitute" && e.tags.includes(cls)).length} |`);
  lines.push("", "Per-word candidate alignments, both replay runs and their archived-final equality are in eval.json. Historical attribution remains UNKNOWN unless an original boundary artifact is available.");
  writeFileSync(join(output, "REPORT.md"), lines.join("\n") + "\n", { mode: 0o600 });
}
if (import.meta.main) await main();
