#!/usr/bin/env bun
import {
  addAlias,
  setPromptPolicy,
  type STTDictionaryEntry,
  listVocabulary,
  removeAlias,
  addPromptTerm,
  removePromptTerm,
  type STTVocabularyStoreOptions,
  type STTVocabularyMutationResult,
} from "../stt-vocabulary-store";

interface VocabularyCliDeps {
  env?: NodeJS.ProcessEnv;
  stdout?: (line: string) => void;
  stderr?: (line: string) => void;
}

type ParsedFlags = Record<string, string[]>;

export async function runVocabularyCli(
  argv: string[],
  deps: VocabularyCliDeps = {},
): Promise<number> {
  const stdout = deps.stdout ?? ((line: string) => process.stdout.write(line));
  const stderr = deps.stderr ?? ((line: string) => process.stderr.write(line));
  const options: STTVocabularyStoreOptions = { env: deps.env ?? process.env };
  const [command, ...rest] = argv;

  try {
    switch (command) {
      case "add": {
        const flags = parseFlags(rest);
        const policy = parsePromptPolicy(flags);
        if (hasFlag(flags, "--wrong") || hasFlag(flags, "--right")) {
          const wrong = requireFlag(flags, "--wrong");
          const right = requireFlag(flags, "--right");
          requireChanged(addAlias({ from: wrong, to: right }, { ...options, promptPolicy: policy }), "variant");
          stdout(`Added variant: ${wrong.trim()} -> ${right.trim()}\n`);
          return 0;
        }
        const term = requireFlag(flags, "--term");
        requireChanged(addPromptTerm(term, { ...options, promptPolicy: policy }), "term");
        const accepted: string[] = [];
        for (const variant of flags["--variant"] ?? []) {
          try {
            requireChanged(addAlias({ from: variant, to: term }, options), "variant");
            accepted.push(variant.trim());
          } catch (error) {
            throw new Error(
              `${error instanceof Error ? error.message : String(error)}; Term ${term.trim()} and accepted variants ${accepted.join(", ") || "(none)"} were saved before this rejection; check current vocabulary state`,
            );
          }
        }
        stdout(`Added term: ${term.trim()}\n`);
        return 0;
      }
      case "add-variant": {
        const flags = parseFlags(rest);
        const term = requireFlag(flags, "--term");
        const variant = requireFlag(flags, "--variant");
        requireChanged(addAlias({ from: variant, to: term }, options), "variant");
        stdout(`Added variant: ${variant.trim()} -> ${term.trim()}\n`);
        return 0;
      }
      case "set-prompt": {
        const flags = parseFlags(rest);
        const policy = parsePromptPolicy(flags);
        if (!policy) throw new Error("--prompt is required");
        const term = requireFlag(flags, "--term");
        setPromptPolicy(term, policy, options);
        stdout(`Prompt policy: ${term.trim()} -> ${policy.prompt}\n`);
        return 0;
      }
      case "list": {
        const snapshot = listVocabulary(options);
        stdout(formatVocabularyList(snapshot));
        return 0;
      }
      case "remove": {
        const flags = parseFlags(rest);
        if (hasFlag(flags, "--wrong")) {
          const wrong = requireFlag(flags, "--wrong");
          const result = removeAlias(wrong, options);
          if (result.removed) {
            stdout(`Removed variant: ${wrong.trim()}\n`);
          } else {
            stdout(`No variant found: ${wrong.trim()}\n`);
          }
          return 0;
        }
        const term = requireFlag(flags, "--term");
        const result = removePromptTerm(term, options);
        if (result.removed) {
          stdout(`Removed term: ${term.trim()}\n`);
        } else {
          stdout(`No term found: ${term.trim()}\n`);
        }
        return 0;
      }
      case "--help":
      case "-h":
      case undefined:
        stdout(usage());
        return 0;
      default:
        stderr(`Unknown vocab command: ${command}\n${usage()}`);
        return 1;
    }
  } catch (error) {
    stderr(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

function parsePromptPolicy(flags: ParsedFlags): Pick<STTDictionaryEntry, "prompt" | "prompt_after" | "prompt_user" | "prompt_order"> | undefined {
  if (!hasFlag(flags, "--prompt")) {
    if (hasFlag(flags, "--prompt-after") || hasFlag(flags, "--prompt-user") || hasFlag(flags, "--prompt-order")) throw new Error("--prompt is required");
    return undefined;
  }
  const prompt = requireFlag(flags, "--prompt");
  if (prompt !== "include" && prompt !== "exclude" && prompt !== "reserve") throw new Error("invalid prompt policy");
  const after = flags["--prompt-after"]?.[0];
  const user = flags["--prompt-user"]?.[0];
  const order = flags["--prompt-order"]?.[0];
  if ((after !== undefined || user !== undefined || order !== undefined) && prompt !== "reserve") throw new Error("reserve options require --prompt reserve");
  if (user !== undefined && user !== "true" && user !== "false") throw new Error("--prompt-user must be true or false");
  if (order !== undefined && (!/^\d+$/.test(order) || !Number.isSafeInteger(Number(order)))) throw new Error("--prompt-order must be a nonnegative safe integer");
  return { prompt, ...(order !== undefined ? { prompt_order: Number(order) } : {}), ...(after !== undefined ? { prompt_after: after.trim() } : {}), ...(user !== undefined ? { prompt_user: user === "true" } : {}) };
}

function requireChanged(result: STTVocabularyMutationResult, mode: "term" | "variant"): void {
  if (result.changed) return;
  const warning = result.warnings?.[0];
  const reason = warning?.code === "same_as_canonical" ? "Already the same as the term"
    : warning?.code === "duplicate_variant" ? "Already listed as a misheard spelling"
    : warning?.code === "dictionary_variant_collision" || (mode === "term" && warning?.code === "dictionary_alias_collision")
      ? `Already a misheard spelling of ${warning.existing}`
      : warning?.code === "dictionary_alias_collision" ? `Already a term: ${warning.existing}`
      : warning?.code === "near_duplicate_canonical" ? `Near duplicate of ${warning.existing}` : "No change";
  throw new Error(`${mode === "term" ? "Term" : "Variant"} not added: ${reason}`);
}

function parseFlags(argv: string[]): ParsedFlags {
  const flags: ParsedFlags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected argument: ${arg}`);
    }
    const value = argv[++i];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`${arg} is required`);
    }
    flags[arg] = [...(flags[arg] ?? []), value];
  }
  return flags;
}

function requireFlag(flags: ParsedFlags, flag: string): string {
  const value = flags[flag]?.[0]?.trim();
  if (!value) {
    throw new Error(`${flag} is required`);
  }
  return value;
}

function hasFlag(flags: ParsedFlags, flag: string): boolean {
  return (flags[flag]?.length ?? 0) > 0;
}

function formatVocabularyList(snapshot: {
  entries: STTDictionaryEntry[];
}): string {
  if (snapshot.entries.length === 0) {
    return "No STT vocabulary entries.\n";
  }

  const lines: string[] = [];
  for (const entry of snapshot.entries) {
    lines.push(`- ${entry.canonical}`);
    if (entry.prompt) {
      lines.push(`  prompt: ${entry.prompt}${entry.prompt_after ? ` after ${entry.prompt_after}` : ""}${entry.prompt_order !== undefined ? ` order ${entry.prompt_order}` : ""}${entry.prompt_user ? " (user tier too)" : ""}`);
    }
    if (entry.variants.length > 0) {
      lines.push(`  variants: ${entry.variants.join(", ")}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

function usage(): string {
  return `Usage: voicelayer vocab <command> [options]

Commands:
  add --term X [--variant V...]      Add a canonical STT term
  add --wrong X --right Y            Back-compat alias add
  add-variant --term X --variant V   Add a misheard variant
  set-prompt --term X --prompt P      Set include (default), exclude, or reserve
  list                               List STT vocabulary entries
  remove --term X                    Remove a canonical STT term

add also accepts --prompt include|exclude|reserve.
Reserve options: --prompt-after TERM places its builtin priority slot;
--prompt-order N orders slots at that anchor (default 0, stable store order);
--prompt-user true|false also retains an existing user-tier position.
Absent or unknown stored policy uses legacy include behavior.
`;
}

if (import.meta.main) {
  runVocabularyCli(Bun.argv.slice(2)).then((code) => {
    process.exit(code);
  });
}
