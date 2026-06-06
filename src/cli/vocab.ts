#!/usr/bin/env bun
import {
  addAlias,
  listVocabulary,
  removeAlias,
  type STTVocabularyStoreOptions,
} from "../stt-vocabulary-store";

interface VocabularyCliDeps {
  env?: NodeJS.ProcessEnv;
  stdout?: (line: string) => void;
  stderr?: (line: string) => void;
}

type ParsedFlags = Record<string, string>;

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
        const wrong = requireFlag(flags, "--wrong");
        const right = requireFlag(flags, "--right");
        addAlias({ from: wrong, to: right }, options);
        stdout(`Added alias: ${wrong.trim()} -> ${right.trim()}\n`);
        return 0;
      }
      case "list": {
        const snapshot = listVocabulary(options);
        stdout(formatVocabularyList(snapshot));
        return 0;
      }
      case "remove": {
        const flags = parseFlags(rest);
        const wrong = requireFlag(flags, "--wrong");
        const result = removeAlias(wrong, options);
        if (result.removed) {
          stdout(`Removed alias: ${wrong.trim()}\n`);
        } else {
          stdout(`No alias found: ${wrong.trim()}\n`);
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
    flags[arg] = value;
  }
  return flags;
}

function requireFlag(flags: ParsedFlags, flag: string): string {
  const value = flags[flag]?.trim();
  if (!value) {
    throw new Error(`${flag} is required`);
  }
  return value;
}

function formatVocabularyList(snapshot: {
  prompt_terms: string[];
  aliases: Array<{ from: string; to: string }>;
}): string {
  if (snapshot.prompt_terms.length === 0 && snapshot.aliases.length === 0) {
    return "No STT vocabulary entries.\n";
  }

  const lines: string[] = [];
  if (snapshot.prompt_terms.length > 0) {
    lines.push("Prompt terms:");
    for (const term of snapshot.prompt_terms) {
      lines.push(`  - ${term}`);
    }
  }
  if (snapshot.aliases.length > 0) {
    lines.push("Aliases:");
    for (const alias of snapshot.aliases) {
      lines.push(`  - ${alias.from} -> ${alias.to}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

function usage(): string {
  return `Usage: voicelayer vocab <command> [options]

Commands:
  add --wrong X --right Y   Add or update an STT alias
  list                      List STT vocabulary entries
  remove --wrong X          Remove an STT alias
`;
}

if (import.meta.main) {
  runVocabularyCli(Bun.argv.slice(2)).then((code) => {
    process.exit(code);
  });
}
