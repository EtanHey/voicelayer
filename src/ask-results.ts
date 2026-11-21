import { lstatSync, readdirSync, readFileSync } from "fs";
import { join } from "path";
import { listOpenAsks, questionPreview, type OpenAsk } from "./open-ask";
import { getRecordingsArchiveRoot } from "./paths";
import { VoiceAskResultsSchema } from "./schemas/mcp-inputs";
import type { McpTextResult } from "./voice-turn-result";

const ID = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/;
type AskResult = { id: string; asked_at: string; question_preview: string; answer: string | null;
  status: "answered" | "away" | "needs-retranscribe" };
function directory(path: string): boolean {
  try { return lstatSync(path).isDirectory(); } catch { return false; }
}
function read(path: string): string | null {
  try { return lstatSync(path).isFile() ? readFileSync(path, "utf8") : null; } catch { return null; }
}
function load(root: string, id: string): AskResult | null {
  const day = join(root, id.slice(0, 10)), dir = join(day, id);
  if (!directory(day) || !directory(dir)) return null;
  try {
    const metadata = JSON.parse(read(join(dir, "metadata.json")) ?? "null");
    if (metadata?.source !== "voice_ask" || (metadata.id && metadata.id !== id) ||
        typeof metadata.created_at !== "string" || !Number.isFinite(Date.parse(metadata.created_at))) return null;
    const answer = read(join(dir, "voicelayer-transcript.txt"));
    let away = false;
    try { away = JSON.parse(read(join(dir, "ask-result.json")) ?? "null")?.status === "away"; } catch {}
    return { id, asked_at: metadata.created_at,
      question_preview: questionPreview(read(join(dir, "agent-transcript.txt")) ?? ""),
      answer, status: answer?.trim() ? "answered" : away ? "away" : "needs-retranscribe" };
  } catch { return null; } // Partial or malformed entries stay out of the page.
}

const OPEN_MESSAGE = "An Ask is still open; its answer is not ready yet. Do not ask the user again. " +
  "Call voice_ask_results later (with its archive_id once it has one) for the answer.";

/**
 * Reads only the paired archive used by VoiceBar's Ask History, plus this process's open asks; never invokes audio,
 * the microphone or STT, and never waits.
 */
export async function handleVoiceAskResults(args: unknown): Promise<McpTextResult> {
  const parsed = VoiceAskResultsSchema.safeParse(args ?? {});
  if (!parsed.success) return { content: [{type: "text", text: "Invalid voice_ask_results arguments: archive_id or limit (integer 1-20)."}], isError: true };
  const root = getRecordingsArchiveRoot();
  let results: AskResult[] = [];
  // An open ask's archive exists before its answer: until answered it is reported as open, not as needing
  // retranscription; once its answer is retained the archive row is the answer and the open row is dropped.
  let open: OpenAsk[] = listOpenAsks();
  const reconcile = (entries: AskResult[]): AskResult[] => {
    const answered = new Set(entries.filter(entry => entry.status === "answered").map(entry => entry.id));
    open = open.filter(ask => !ask.archive_id || !answered.has(ask.archive_id));
    const pending = new Set(open.map(ask => ask.archive_id));
    return entries.filter(entry => !pending.has(entry.id));
  };
  if (parsed.data.archive_id) {
    const entry = load(root, parsed.data.archive_id);
    open = open.filter(ask => ask.archive_id === parsed.data.archive_id);
    results = reconcile(entry ? [entry] : []);
    const message = open.length ? OPEN_MESSAGE : results.length === 0 ? "No Ask answer exists for this archive ID." : null;
    return { content: [{ type: "text", text: JSON.stringify({ results, ...(open.length ? { open } : {}), ...(message ? { message } : {}) }) }] };
  } else {
    try {
      for (const day of readdirSync(root).filter(day => /^\d{4}-\d{2}-\d{2}$/.test(day))) {
        if (!directory(join(root, day))) continue;
        for (const id of readdirSync(join(root, day))) {
          if (!ID.test(id) || !id.startsWith(day)) continue;
          const entry = load(root, id);
          if (entry) results.push(entry);
        }
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") return {content: [{type: "text", text: "Ask archive could not be read."}], isError: true};
    }
    results.sort((a, b) => Date.parse(b.asked_at) - Date.parse(a.asked_at) || b.id.localeCompare(a.id));
    results = reconcile(results).slice(0, parsed.data.limit);
  }
  return { content: [{ type: "text", text: JSON.stringify({ results, ...(open.length ? { open, message: OPEN_MESSAGE } : {}) }) }] };
}
