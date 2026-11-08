/** Explicit private-archive eval. Run with nice -n 15 bun run scripts/dictation-loss-eval.ts ...
 * --archive DIR --start ID --output DIR (must be gitignored docs.local)
 * --python PATH --parakeet-model DIR --whisper-model FILE --polish-model DIR
 * Optional --vocabulary FILE --processing-settings FILE --manifest FILE (JSON take-id array).
 * No downloads or live engines. Full archive WAVs are used; live PTT input trimming is not replayed.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { getPriority, homedir } from "node:os";
import { connect, createServer } from "node:net";
import { createHash } from "node:crypto";
import { z } from "zod";
import { alignLoss, lossWords, stageEdges, LOSS_CLASSES, referenceComparisons, referenceSkipReason, eligibleReplayEdges, summarizePolishReplays, type PolishReplayEvidence } from "../src/dictation-loss-eval";
import { compareTranscriptToReference } from "../src/stt-decode-benchmark";

const Metadata = z.object({ transcription_status: z.string().optional(), backend: z.string().optional(),
  duration_ms: z.number().optional(), transcribed_duration_ms: z.number().optional(),
  last_stt_gate_removal: z.unknown().optional() }).passthrough();
const Native = z.object({ text: z.string(), last_token_end_s: z.number().nullable(), input_frames: z.number(),
  covered_frames: z.number(), complete: z.boolean(), raw_token_times: z.array(z.unknown()).optional() }).passthrough();
const Reply = z.object({ ok: z.boolean(), id: z.number(), attempt: Native.optional() }).passthrough();
type Replay = PolishReplayEvidence & {
  reason: string | null; reproducesArchive: boolean; stages: Parameters<typeof stageEdges>[0];
  rawVsStages: { stage: string; edits: ReturnType<typeof alignLoss> }[];
  candidateText: string | null; candidateEdits: ReturnType<typeof alignLoss> | null;
};
const CachedDecode = z.object({ decodeIdentity: z.string(), hash: z.string(), native: Native.nullable(), nativeError: z.string().nullable(),
  reference: z.string(), gated: z.string(), outro: z.string(), segments: z.array(z.object({ text: z.string(), startS: z.number(), endS: z.number() })) });
export function parseDecodeCache(value: unknown, identity: { decodeIdentity: string; hash: string }) {
  const parsed = CachedDecode.safeParse(value);
  if (!parsed.success) throw new Error("Decode cache is invalid; use a fresh private output directory");
  if (parsed.data.decodeIdentity !== identity.decodeIdentity || parsed.data.hash !== identity.hash)
    throw new Error("Decode cache does not match audio/model configuration; use a fresh private output directory");
  return parsed.data;
}
export function repoCacheDirectory(): string { return resolve(import.meta.dir, "../.build.noindex/dictation-loss-cache"); }
export function validateOutputPath(requested: string, archive: string): string {
  let existing = resolve(requested); const missing: string[] = [];
  while (!existsSync(existing)) { missing.unshift(basename(existing)); existing = dirname(existing); }
  if (!statSync(existing).isDirectory()) throw new Error("Output parent is not a directory");
  const output = resolve(realpathSync(existing), ...missing);
  if (!output.split(sep).includes("docs.local") || output === archive || output.startsWith(archive + sep))
    throw new Error("Output must be private docs.local outside the archive");
  if (Bun.spawnSync(["git", "-C", realpathSync(existing), "check-ignore", "-q", output], { env: process.env }).exitCode !== 0)
    throw new Error("Output is not gitignored");
  return output;
}
export function selectFrozenTakes<T extends { id: string }>(takes: T[], ids?: readonly string[]): T[] {
  if (!ids) return takes;
  if (!ids.length || new Set(ids).size !== ids.length) throw new Error("Manifest requires nonempty unique take IDs");
  const byId = new Map<string, T>(); for (const take of takes) byId.set(take.id, take);
  return ids.map(id => { const take = byId.get(id); if (!take) throw new Error(`Manifest take is missing from archive: ${id}`); return take; });
}
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
/** Retry only an observed busy host; unavailable or malformed state still fails closed. */
export async function waitForIdle(check: () => Promise<void> = idleState, pause: () => Promise<unknown> = () => Bun.sleep(5000)): Promise<void> {
  for (let attempt = 0; attempt < 60; attempt++) {
    try { await check(); return; }
    catch (error) {
      if (!(error instanceof Error) || !error.message.startsWith("BUSY:") || attempt === 59) throw error;
      if (attempt === 0) console.log("VoiceBar busy; backing off before offline work");
      await pause();
    }
  }
}
function args(argv: string[]) {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i], value = argv[i + 1];
    if (!key?.startsWith("--") || !value || value.startsWith("--")) throw new Error("Expected --flag value pairs; see script header");
    if (!["archive", "start", "output", "python", "parakeet-model", "whisper-model", "polish-model", "vocabulary", "processing-settings", "attempts", "journal", "manifest"].includes(key.slice(2))) throw new Error(`Unknown option ${key}`);
    values.set(key.slice(2), value);
  }
  const required = (key: string) => { const v = values.get(key); if (!v) throw new Error(`Missing --${key}`); return v; };
  return { archive: realpathSync(required("archive")), start: required("start"), output: resolve(required("output")),
    python: resolve(required("python")), parakeet: realpathSync(required("parakeet-model")),
    whisper: realpathSync(required("whisper-model")), polish: realpathSync(required("polish-model")),
    vocabulary: values.get("vocabulary"), settings: values.get("processing-settings"), attempts: values.get("attempts"), journal: values.get("journal"), manifest: values.get("manifest") };
}
function save(path: string, value: unknown) { writeFileSync(path, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 }); }
async function main() {
  const options = args(process.argv.slice(2));
  const decodeIdentity = createHash("sha256").update(JSON.stringify({ version: 1, python: options.python, parakeet: options.parakeet,
    whisper: options.whisper, assets: [options.whisper, join(options.parakeet, "model.safetensors"), join(options.parakeet, "config.json")]
      .map(path => ({ path, bytes: statSync(path).size, mtimeMs: statSync(path).mtimeMs })), worker: readFileSync(join(import.meta.dir, "../src/parakeet-worker.py"), "utf8"),
    reference: "whisper.cpp-large-v3-turbo-auto-default-best5-beam5-no-prompt" })).digest("hex");
  if (getPriority() < 15) throw new Error("Run with nice -n 15 (children inherit low priority)");
  const output = validateOutputPath(options.output, options.archive);
  mkdirSync(output, { recursive: true, mode: 0o700 });
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
    XDG_CACHE_HOME: repoCacheDirectory(),
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
  const discovered = readdirSync(options.archive, { withFileTypes: true }).filter(d => d.isDirectory()).flatMap(d =>
    readdirSync(join(options.archive, d.name), { withFileTypes: true }).filter(t => t.isDirectory() && t.name >= options.start)
      .map(t => ({ id: t.name, dir: join(options.archive, d.name, t.name) }))).sort((a, b) => a.id.localeCompare(b.id));
  const manifest = options.manifest ? z.array(z.string().min(1)).parse(JSON.parse(readFileSync(options.manifest, "utf8"))) : undefined;
  const takes = selectFrozenTakes(discovered, manifest);
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
      await waitForIdle();
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
      decoded = parseDecodeCache(JSON.parse(readFileSync(cachePath, "utf8")), { decodeIdentity, hash });
    } else {
      await waitForIdle();
      let reference = "", outro = "";
      let segments: { text: string; startS: number; endS: number }[] = [];
      const backend = new WhisperCppBackend({ noVocabularyPrompt: true, captionGate: async (text, wav, gateOptions) => {
        segments = gateOptions?.segments ?? []; reference = gateOptions?.segmentsText ?? ""; outro = text;
        return stripHallucinatedCaption(text, wav, gateOptions);
      } });
      const result = await backend.transcribe(audio);
      const native = referenceSkipReason(reference) ? { native: null, nativeError: "not run: empty independent reference" } : await nativeDecode();
      decoded = { decodeIdentity, hash, ...native, reference, gated: result.text, outro, segments };
      save(cachePath, decoded);
    }
    const emptyReason = referenceSkipReason(decoded.reference);
    if (emptyReason) { results.push({ id: take.id, skipped: emptyReason, metadata, decodeCachePath: cachePath }); continue; }
    const wav = new Uint8Array(readFileSync(audio)), windows = measureWavWindows(wav);
    await waitForIdle();
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
        ? [{ index, segmentStartS: segment.startS, boundaryS, evidence: "reference-only chance-noise/counterfactual; not product seam timing" }] : [];
    });
    const fallback = metadata.backend?.includes("fallback") ?? false;
    const raw = decoded.native?.text ?? decoded.reference;
    const matched = originals.filter(o => o.value.inputSha256 === hash);
    const originalFallback = matched.find(o => o.value.stage === "fallback-terminal")?.value.whisper?.text;
    const replays: Replay[] = [];
    results.push({ id: take.id, metadata, archived, ...decoded, tailEnergy, tailStartS: end, audioDurationS: duration, replays,
      sttInputWindow: { replayed: false, archiveDurationMs: info.dataSize / info.sampleRate / 2 * 1000,
        recordedLiveInputMs: metadata.transcribed_duration_ms ?? null,
        limit: "Full archived WAV replay. Live PTT can trim to last Silero speech +3s or a physical-press cutoff; capture boundary state was not archived." },
      originalBoundaries: matched,
      rawKind: decoded.native ? "same-backend re-decode; historical boundaries listed separately" : "reference-raw stand-in",
      pipelineInput: fallback ? originalFallback ? "hash-matched original post-gate Whisper" : "independent Whisper stand-in for historical fallback" : decoded.native ? "same-backend re-decode" : "reference-raw stand-in",
      inputText: fallback ? originalFallback ?? decoded.gated : raw,
      backendSelectionEdge: stageEdges([{ name: "parakeet-raw", text: raw },
        { name: fallback ? "fallback-selection" : "backend-output", text: fallback ? originalFallback ?? decoded.gated : raw }])[0],
      referenceComparison: { ...compareTranscriptToReference(archived, decoded.gated), source: "gated-independent-reference-hypothesis" },
      ...referenceComparisons({ ungated: decoded.reference, gated: decoded.gated, raw, finalText: archived, seamWords: seamCandidates.map(s => s.index) }),
      seamCandidates, rawVsFinal: alignLoss(raw, archived),
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
  await waitForIdle();
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
      const cleaned = finalizeTranscriptionText(take.inputText, config);
      for (let repeat = 0; repeat < 2; repeat++) {
        await waitForIdle();
        if (!ownsListener()) throw new Error("Lost isolated polish listener ownership");
        const polish = await polishTranscriptionText({ rawText: take.inputText, cleanedText: cleaned, surface: "dictation",
          env: { ...config, QA_VOICE_STT_POLISH_ENDPOINT: endpoint + "/v1/chat/completions", QA_VOICE_STT_POLISH_MODEL: options.polish } });
        const paragraphs = applyCoherentParagraphFallback(polish.text);
        const stages = [{ name: "backend-output", text: take.inputText }, { name: "dictionary_rules", text: cleaned },
          { name: "polish", text: polish.text }, { name: "paragraphs", text: paragraphs }];
        take.replays.push({ status: polish.status, reason: polish.reason ?? null, failureKind: polish.failureKind ?? null,
          candidateText: polish.polishedText, candidateEdits: polish.polishedText === null ? null : alignLoss(cleaned, polish.polishedText), reproducesArchive: paragraphs === take.archived,
          stages, rawVsStages: stages.map(stage => ({ stage: stage.name, edits: alignLoss(take.native?.text ?? take.reference, stage.text) })),
          edges: stageEdges(stages) });
      }
    }
  } catch (error) { polishBlocker = error instanceof Error ? error.message : "Polish failed"; }
  finally { server.kill("SIGTERM"); const timer = setTimeout(() => server.kill("SIGKILL"), 3000); await server.exited; clearTimeout(timer); await drains; }
  const observedPolish = summarizePolishReplays(results.flatMap(take => "inputText" in take ? take.replays : []));
  const plannedPolish = results.filter(take => "inputText" in take).length * 2;
  const polishSummary = { ...observedPolish, planned: plannedPolish, notAttempted: plannedPolish - observedPolish.total };
  const report = { polishSummary, generatedAt: new Date().toISOString(), base: "870b16170907bf49862027e240771059d9bd8afe", options, polishBlocker, events, results };
  save(join(output, "eval.json"), report);
  const lines = ["# Dictation loss eval", "", "Status: measurement only; original raw exists only for hash-matched retained fallback boundaries. No human-verified reference. Decode disagreements are candidates.",
    "", `Base: ${report.base}. Snapshot: ${report.generatedAt}. Independent reference: large-v3-turbo, accurate, no vocabulary prompt.`,
    "", "Gates precede dictionary/polish. Reference gate edges are counterfactual on ordinary Parakeet takes. Fallback uses hash-matched original post-gate Whisper when available; otherwise a labelled reference stand-in.",
    "Idle guard: native socket connectivity plus the daemon-published recording-state file and owner PID liveness; native socket has no health reply.",
    "Full archive WAVs are decoded. Live PTT can trim to last Silero speech +3s on silence expiry or a physical-press cutoff; exact capture state was not archived, so this input stage is NOT replayed. Metadata input durations are recorded per take.",
    "Energy after the last token is an acoustic heuristic, not proof of speech. Seam rows are chance-noise/counterfactual, not product timing or headline evidence.",
    "Reference gate replay is counterfactual: historical explicitLanguage is omitted; the isolated CLI's internal speech probe is unavailable and the offline replay compensates for English closers, not historical CJK gating.",
    "Admission is TOCTOU: a dictation starting during inference is not paused; only the low process priority protects it.",
    `Polish applied coverage: ${polishSummary.applied}/${polishSummary.total} observed; planned=${polishSummary.planned}, not-attempted=${polishSummary.notAttempted}; statuses=${JSON.stringify(polishSummary.statuses)}; failures=${JSON.stringify(polishSummary.failures)}. Only applied polish edges enter edit totals. Zero applied observations mean unknown, not zero loss.`,
    "Polish is replayed twice; paragraph replay uses the text-only fallback (original pause-map context unavailable). Token deletions can be alias joins or command formatting; they are not all speech losses.", "", `Polish blocker: ${polishBlocker ?? "none"}.`, "",
    "| Take | Status/backend | Gated reference vs raw | Gated reference vs final | Raw vs final | Polish statuses | Archive matches |", "|---|---|---:|---:|---:|---|---|",
    ...results.map(t => "skipped" in t ? `| ${t.id} | SKIP: ${t.skipped} | — | — | — | — | — |` : `| ${t.id} | ${t.metadata.backend} | ${t.referenceGatedVsRaw.length} | ${t.referenceVsFinal.length} | ${t.rawVsFinal.length} | ${t.replays.map(r => r.failureKind ? r.status + "/" + r.failureKind : r.status).join(", ")} | ${t.replays.filter(r => r.reproducesArchive).length}/2 |`), "",
    "## Candidate class totals (multi-label; substitutions separated from deletions)", "", "| Comparison | Class | Deleted | Substituted |", "|---|---|---:|---:|"];
  const comparisons = new Map<string, ReturnType<typeof alignLoss>>();
  for (const take of results) if ("rawVsFinal" in take) {
    for (const [label, edits] of [["raw → archived (historical stage unknown)", take.rawVsFinal], ["gated reference → raw (decoder disagreement)", take.referenceGatedVsRaw], ["gated reference → archived", take.referenceVsFinal], ["ungated reference → raw (noise/counterfactual)", take.referenceUngatedVsRaw]] as const) comparisons.set(label, [...(comparisons.get(label) ?? []), ...edits]);
    const replayEdges = take.replays[0] ? eligibleReplayEdges(take.replays[0]) : [];
    for (const edge of [...take.gateEdges, take.backendSelectionEdge, ...replayEdges]) {
      const label = `replay ${edge.from} → ${edge.to}${edge.to === "polish" ? " (applied only)" : edge.from === "reference-raw" || edge.to === "caption" ? " (gate counterfactual)" : ""}`; comparisons.set(label, [...(comparisons.get(label) ?? []), ...edge.edits]);
    }
  }
  for (const [label, edits] of comparisons) for (const cls of LOSS_CLASSES) lines.push(`| ${label} | ${cls === "seam/chunk-boundary" ? cls + " (noise/counterfactual)" : cls} | ${edits.filter(e => e.kind === "delete" && e.tags.includes(cls)).length} | ${edits.filter(e => e.kind === "substitute" && e.tags.includes(cls)).length} |`);
  lines.push("", "Per-word candidate alignments, both replay runs and their archived-final equality are in eval.json. Historical attribution remains UNKNOWN unless an original boundary artifact is available.");
  writeFileSync(join(output, "REPORT.md"), lines.join("\n") + "\n", { mode: 0o600 });
}
if (import.meta.main) await main();
