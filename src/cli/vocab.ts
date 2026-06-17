#!/usr/bin/env bun
import {
  addAlias,
  listVocabulary,
  removeAlias,
  addPromptTerm,
  removePromptTerm,
  type STTVocabularyStoreOptions,
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
        if (hasFlag(flags, "--wrong") || hasFlag(flags, "--right")) {
          const wrong = requireFlag(flags, "--wrong");
          const right = requireFlag(flags, "--right");
          addAlias({ from: wrong, to: right }, options);
          stdout(`Added variant: ${wrong.trim()} -> ${right.trim()}\n`);
          return 0;
        }
        const term = requireFlag(flags, "--term");
        addPromptTerm(term, options);
        for (const variant of flags["--variant"] ?? []) {
          addAlias({ from: variant, to: term }, options);
        }
        stdout(`Added term: ${term.trim()}\n`);
        return 0;
      }
      case "add-variant": {
        const flags = parseFlags(rest);
        const term = requireFlag(flags, "--term");
        const variant = requireFlag(flags, "--variant");
        addAlias({ from: variant, to: term }, options);
        stdout(`Added variant: ${variant.trim()} -> ${term.trim()}\n`);
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
  entries: Array<{ canonical: string; variants: string[] }>;
}): string {
  if (snapshot.entries.length === 0) {
    return "No STT vocabulary entries.\n";
  }

  const lines: string[] = [];
  for (const entry of snapshot.entries) {
    lines.push(`- ${entry.canonical}`);
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
  list                               List STT vocabulary entries
  remove --term X                    Remove a canonical STT term
`;
}

if (import.meta.main) {
  runVocabularyCli(Bun.argv.slice(2)).then((code) => {
    process.exit(code);
  });
}
