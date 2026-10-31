import { readPersonalPronunciations, updatePersonalPronunciation } from "../pronunciation";

const usage = "Usage: voicelayer pronounce add --term X --say Y | list | remove --term X\n";
export function runPronunciationCli(argv: string[], options: {
  env?: NodeJS.ProcessEnv; stdout?: (text: string) => void; stderr?: (text: string) => void;
} = {}): number {
  const { env = process.env, stdout = text => process.stdout.write(text), stderr = text => process.stderr.write(text) } = options;
  try {
    const [command, ...args] = argv;
    if (command === "--help" || command === "-h" || !command) { stdout(usage); return 0; }
    const flags = new Map<string, string>();
    for (let i = 0; i < args.length; i += 2) {
      if (!["--term", "--say"].includes(args[i]) || !args[i + 1] || flags.has(args[i])) throw new Error(usage);
      flags.set(args[i], args[i + 1]);
    }
    if (command === "list" && !flags.size) {
      const entries = Object.entries(readPersonalPronunciations(env));
      stdout(entries.length ? entries.map(([term, say]) => `${term} -> ${say}\n`).join("") : "No personal pronunciations.\n");
    } else if (command === "add" && flags.size === 2 && flags.has("--term") && flags.has("--say")) {
      updatePersonalPronunciation(flags.get("--term")!, flags.get("--say")!, env);
      stdout("Pronunciation saved.\n");
    } else if (command === "remove" && flags.size === 1 && flags.has("--term")) {
      updatePersonalPronunciation(flags.get("--term")!, undefined, env);
      stdout("Pronunciation removed.\n");
    } else throw new Error(usage);
    return 0;
  } catch (error) { stderr(`${error instanceof Error ? error.message : String(error)}\n`); return 1; }
}

if (import.meta.main) process.exit(runPronunciationCli(Bun.argv.slice(2)));
