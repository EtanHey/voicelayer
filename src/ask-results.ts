import { lstatSync, readdirSync, readFileSync } from "fs";
import { join } from "path";
import { listOpenAsks, questionPreview, type OpenAsk } from "./open-ask";
import { getRecordingsArchiveRoot } from "./paths";
import { VoiceAskResultsSchema } from "./schemas/mcp-inputs";
import type { McpTextResult } from "./voice-turn-result";

const ID = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/;
type AskResult = { id: string; asked_at: string; question_preview: string; answer: string | null;
  error?: string; status: "answered" | "away" | "needs-retranscribe" | "unreadable" };
function directory(path: string): boolean {
  try { return lstatSync(path).isDirectory(); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; return false; }
}
function read(path: string): string | null {
  try { return lstatSync(path).isFile() ? readFileSync(path, "utf8") : null; } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; return null; }
}
function preview(path: string): string {
  try { return questionPreview(read(path) ?? ""); } catch { return ""; }
}
function unreadable(id: string, error: unknown): AskResult {
  const code = (error as NodeJS.ErrnoException)?.code;
  return { id, asked_at: id.length === 10 ? id : id.slice(0, 10) + "T" + id.slice(11, 23).replace(/-/g, (m, offset) => offset < 8 ? ":" : "." ) + "Z", question_preview: "", answer: null, status: "unreadable", error: typeof code === "string" && /^[A-Z0-9_]+$/.test(code) ? code : "UNKNOWN" };
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
    try { away = JSON.parse(read(join(dir, "ask-result.json")) ?? "null")?.status === "away"; } catch (error) { if (!(error instanceof SyntaxError)) throw error; }
    return { id, asked_at: metadata.created_at,
      question_preview: preview(join(dir, "agent-transcript.txt")),
      answer, status: answer?.trim() ? "answered" : away ? "away" : "needs-retranscribe" };
  } catch (error) { if (error instanceof SyntaxError) return null; throw error; } // Malformed entries stay out of the page.
}

function storageError(id: string, error: unknown): McpTextResult {
  const code = (error as NodeJS.ErrnoException)?.code;
  return { content: [{type: "text", text: `Ask archive ${id} could not be read (${typeof code === "string" && /^[A-Z0-9_]+$/.test(code) ? code : "UNKNOWN"}).` }], isError: true };
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
    let entry: AskResult | null;
    try { entry = load(root, parsed.data.archive_id); } catch (error) { return storageError(parsed.data.archive_id, error); }
    open = open.filter(ask => ask.archive_id === parsed.data.archive_id);
    results = reconcile(entry ? [entry] : []);
    const message = open.length ? OPEN_MESSAGE : results.length === 0 ? "No Ask answer exists for this archive ID." : null;
    return { content: [{ type: "text", text: JSON.stringify({ results, ...(open.length ? { open } : {}), ...(message ? { message } : {}) }) }] };
  } else {
    try {
      for (const day of readdirSync(root).filter(day => /^\d{4}-\d{2}-\d{2}$/.test(day))) {
        let ids: string[];
        try {
          if (!directory(join(root, day))) continue;
          ids = readdirSync(join(root, day));
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") results.push(unreadable(day, error));
          continue;
        }
        for (const id of ids) {
          if (!ID.test(id) || !id.startsWith(day)) continue;
          let entry: AskResult | null;
          try { entry = load(root, id); } catch (error) { results.push(unreadable(id, error)); continue; }
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
