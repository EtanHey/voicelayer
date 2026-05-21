import { existsSync } from "fs";
import { resolve } from "path";
import {
  buildCleanupPairsFromRecordings,
  buildSTTQualityMiningReport,
  defaultPolishLogPath,
  loadCorrectionPairsFromJsonl,
  loadFreshDecodesFromBenchmarkReports,
  loadPolishPairsFromJsonl,
  loadVoiceBarRecordings,
  writeSTTQualityMiningReport,
} from "../src/stt-quality-mining";

interface CliOptions {
  archiveRoot?: string;
  since?: Date;
  until: Date;
  days: number;
  limit?: number;
  benchmarkJson: string[];
  polishLog?: string;
  correctionsJsonl: string[];
  includeCleanup: boolean;
  outputDir: string;
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    until: new Date(),
    days: 7,
    benchmarkJson: [],
    correctionsJsonl: [],
    includeCleanup: true,
    outputDir: "docs.local/research",
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--archive-root") {
      options.archiveRoot = requiredValue(argv, ++i, arg);
    } else if (arg === "--since") {
      options.since = parseDate(requiredValue(argv, ++i, arg), arg);
    } else if (arg === "--until") {
      options.until = parseDate(requiredValue(argv, ++i, arg), arg);
    } else if (arg === "--days") {
      options.days = parsePositiveInteger(requiredValue(argv, ++i, arg), arg);
    } else if (arg === "--limit") {
      options.limit = parsePositiveInteger(requiredValue(argv, ++i, arg), arg);
    } else if (arg === "--benchmark-json") {
      options.benchmarkJson.push(resolve(requiredValue(argv, ++i, arg)));
    } else if (arg === "--polish-log") {
      options.polishLog = resolve(requiredValue(argv, ++i, arg));
    } else if (arg === "--corrections-jsonl") {
      options.correctionsJsonl.push(resolve(requiredValue(argv, ++i, arg)));
    } else if (arg === "--no-polish-log") {
      options.polishLog = "";
    } else if (arg === "--no-cleanup") {
      options.includeCleanup = false;
    } else if (arg === "--output-dir") {
      options.outputDir = resolve(requiredValue(argv, ++i, arg));
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

function requiredValue(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value) throw new Error(`${flag} requires a value`);
  return value;
}

function parseDate(value: string, flag: string): Date {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new Error(`${flag} requires a valid date or ISO timestamp`);
  }
  return date;
}

function parsePositiveInteger(value: string, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} requires a positive integer`);
  }
  return parsed;
}

function printUsage(): void {
  console.log(`Usage: bun run scripts/mine-stt-quality.ts [options]

Options:
  --days N              Days to include before --until. Default: 7.
  --since DATE          Inclusive start date/timestamp. Overrides --days.
  --until DATE          Exclusive end date/timestamp. Default: now.
  --archive-root DIR    VoiceBar archive root. Default: ~/.local/share/voicelayer/recordings.
  --limit N             Analyze only the latest N recordings in the selected window.
  --benchmark-json PATH Fresh decode benchmark JSON. Repeatable.
  --polish-log PATH     Local polish shadow JSONL. Default: ~/.voicelayer/eval/polish-shadow.jsonl when present.
  --corrections-jsonl PATH
                        User correction pairs JSONL. Repeatable. Rows accept
                        observed_text/expected_text or observed/expected.
  --no-polish-log       Do not read polish shadow JSONL.
  --no-cleanup          Skip deterministic cleanup pair analysis.
  --output-dir DIR      Report output directory. Default: docs.local/research.

This script is local-only. It reads VoiceBar archives, optional local benchmark
JSON, and optional local polish shadow logs. It does not upload audio or
transcripts, does not query Wispr Flow, and does not write Wispr dictionaries.`);
}

function windowStart(options: CliOptions): Date {
  if (options.since) return options.since;
  return new Date(options.until.getTime() - options.days * 24 * 60 * 60 * 1000);
}

function existingBenchmarkPaths(paths: string[]): string[] {
  const missing = paths.filter((path) => !existsSync(path));
  if (missing.length > 0) {
    throw new Error(`Benchmark JSON not found: ${missing.join(", ")}`);
  }
  return paths;
}

function existingJsonlPaths(paths: string[], label: string): string[] {
  const missing = paths.filter((path) => !existsSync(path));
  if (missing.length > 0) {
    throw new Error(`${label} not found: ${missing.join(", ")}`);
  }
  return paths;
}

function polishLogPath(options: CliOptions): string | null {
  if (options.polishLog === "") return null;
  if (options.polishLog) {
    if (!existsSync(options.polishLog)) {
      throw new Error(`Polish shadow JSONL not found: ${options.polishLog}`);
    }
    return options.polishLog;
  }
  const path = defaultPolishLogPath();
  return existsSync(path) ? path : null;
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  const since = windowStart(options);
  const recordings = loadVoiceBarRecordings({
    archiveRoot: options.archiveRoot,
    since,
    until: options.until,
    limit: options.limit,
  });
  const freshDecodes = loadFreshDecodesFromBenchmarkReports(
    existingBenchmarkPaths(options.benchmarkJson),
  );
  const cleanupPairs = options.includeCleanup
    ? buildCleanupPairsFromRecordings(recordings)
    : [];
  const polishPath = polishLogPath(options);
  const polishPairs = polishPath
    ? loadPolishPairsFromJsonl(polishPath, { since, until: options.until })
    : [];
  const correctionPairs = existingJsonlPaths(
    options.correctionsJsonl,
    "Corrections JSONL",
  ).flatMap(loadCorrectionPairsFromJsonl);
  const report = buildSTTQualityMiningReport({
    recordings,
    freshDecodes,
    cleanupPairs,
    polishPairs,
    correctionPairs,
  });
  const written = writeSTTQualityMiningReport(report, options.outputDir);

  console.log(`Window: ${since.toISOString()} to ${options.until.toISOString()}`);
  console.log(`Recordings: ${report.summary.recordings}`);
  console.log(`Fresh decodes: ${report.summary.freshDecodes}`);
  console.log(`Cleanup pairs: ${report.summary.cleanupPairs}`);
  console.log(`Polish pairs: ${report.summary.polishPairs}`);
  console.log(`User correction pairs: ${report.summary.correctionPairs}`);
  console.log(`Findings: ${report.summary.findings}`);
  console.log(`Wrote ${written.jsonPath}`);
  console.log(`Wrote ${written.markdownPath}`);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
