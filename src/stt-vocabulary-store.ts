import {
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { homedir } from "os";
import { basename, dirname, join } from "path";

const VOCABULARY_PATH_ENV = "QA_VOICE_STT_VOCABULARY_PATH";
const DEFAULT_LOCK_TIMEOUT_MS = 3000;
const DEFAULT_STALE_LOCK_MS = 30_000;

export const UNSAFE_DYNAMIC_ALIAS_SOURCES = new Set([
  // Wispr-derived history can include broad aliases that are correct in a
  // session-mining context but corrupt ordinary audio vocabulary.
  "codecs",
]);

export interface STTVocabularyAlias {
  from: string;
  to: string;
}

export interface STTVocabularySnapshot {
  updated_at: string | null;
  prompt_terms: string[];
  aliases: STTVocabularyAlias[];
}

export interface STTVocabularyStoreOptions {
  path?: string;
  env?: NodeJS.ProcessEnv;
  now?: () => Date;
  lockTimeoutMs?: number;
  staleLockMs?: number;
}

export type STTVocabularyMutationResult = STTVocabularySnapshot & {
  changed: boolean;
  removed?: boolean;
};

interface RawVocabularySnapshot {
  updated_at?: unknown;
  prompt_terms?: unknown;
  aliases?: unknown;
}

export function getSTTVocabularyPath(
  options: STTVocabularyStoreOptions = {},
): string {
  if (options.path) return options.path;
  const env = options.env ?? process.env;
  const override = env[VOCABULARY_PATH_ENV]?.trim();
  return (
    override ||
    join(homedir(), ".local", "state", "voicelayer", "stt-vocabulary.json")
  );
}

export function isUnsafeDynamicAliasSource(source: string): boolean {
  return UNSAFE_DYNAMIC_ALIAS_SOURCES.has(source.trim().toLowerCase());
}

export function listVocabulary(
  options: STTVocabularyStoreOptions = {},
): STTVocabularySnapshot {
  return readSnapshot(getSTTVocabularyPath(options));
}

export function addAlias(
  alias: STTVocabularyAlias,
  options: STTVocabularyStoreOptions = {},
): STTVocabularyMutationResult {
  const normalized = validateAlias(alias);
  const path = getSTTVocabularyPath(options);
  return withVocabularyLock(path, options, () => {
    const snapshot = readSnapshot(path);
    const existingIndex = snapshot.aliases.findIndex(
      (entry) => entry.from.toLowerCase() === normalized.from.toLowerCase(),
    );
    if (existingIndex >= 0) {
      snapshot.aliases[existingIndex] = {
        from: snapshot.aliases[existingIndex].from,
        to: normalized.to,
      };
    } else {
      snapshot.aliases.push(normalized);
    }
    return writeSnapshot(path, stampSnapshot(snapshot, options), true);
  });
}

export function addPromptTerm(
  term: string,
  options: STTVocabularyStoreOptions = {},
): STTVocabularyMutationResult {
  const normalized = validateText(term, "term");
  const path = getSTTVocabularyPath(options);
  return withVocabularyLock(path, options, () => {
    const snapshot = readSnapshot(path);
    const exists = snapshot.prompt_terms.some(
      (entry) => entry.toLowerCase() === normalized.toLowerCase(),
    );
    if (!exists) {
      snapshot.prompt_terms.push(normalized);
    }
    return writeSnapshot(path, stampSnapshot(snapshot, options), true);
  });
}

export function removeAlias(
  from: string,
  options: STTVocabularyStoreOptions = {},
): STTVocabularyMutationResult {
  const normalizedFrom = validateAliasSource(from);
  const path = getSTTVocabularyPath(options);
  return withVocabularyLock(path, options, () => {
    const snapshot = readSnapshot(path);
    const aliases = snapshot.aliases.filter(
      (entry) => entry.from.toLowerCase() !== normalizedFrom.toLowerCase(),
    );
    const removed = aliases.length !== snapshot.aliases.length;
    if (!removed) {
      return { ...snapshot, changed: false, removed: false };
    }
    snapshot.aliases = aliases;
    return {
      ...writeSnapshot(path, stampSnapshot(snapshot, options), true),
      removed,
    };
  });
}

function validateAlias(alias: STTVocabularyAlias): STTVocabularyAlias {
  const from = validateAliasSource(alias.from);
  const to = validateText(alias.to, "to");
  if (from.toLowerCase() === to.toLowerCase()) {
    throw new Error("from and to must be different");
  }
  return { from, to };
}

function validateAliasSource(value: string): string {
  const from = validateText(value, "from");
  if (isUnsafeDynamicAliasSource(from)) {
    throw new Error("unsafe alias source");
  }
  return from;
}

function validateText(value: string, label: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new Error(`${label} is required`);
  }
  return trimmed;
}

function readSnapshot(path: string): STTVocabularySnapshot {
  if (!existsSync(path)) {
    return { updated_at: null, prompt_terms: [], aliases: [] };
  }

  const parsed = JSON.parse(readFileSync(path, "utf8")) as RawVocabularySnapshot;
  return normalizeSnapshot(parsed);
}

function normalizeSnapshot(
  parsed: RawVocabularySnapshot,
): STTVocabularySnapshot {
  const promptTerms = Array.isArray(parsed.prompt_terms)
    ? dedupeStrings(parsed.prompt_terms.filter(isNonEmptyString))
    : [];
  const aliases: STTVocabularyAlias[] = [];
  if (Array.isArray(parsed.aliases)) {
    for (const entry of parsed.aliases) {
      if (!entry || typeof entry !== "object") continue;
      const { from, to } = entry as Partial<STTVocabularyAlias>;
      if (!isNonEmptyString(from) || !isNonEmptyString(to)) continue;
      const normalizedFrom = from.trim();
      if (isUnsafeDynamicAliasSource(normalizedFrom)) continue;
      upsertAlias(aliases, {
        from: normalizedFrom,
        to: to.trim(),
      });
    }
  }
  return {
    updated_at:
      typeof parsed.updated_at === "string" && parsed.updated_at.trim()
        ? parsed.updated_at
        : null,
    prompt_terms: promptTerms,
    aliases,
  };
}

function dedupeStrings(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const trimmed = value.trim();
    const key = trimmed.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(trimmed);
  }
  return result;
}

function upsertAlias(
  aliases: STTVocabularyAlias[],
  alias: STTVocabularyAlias,
): void {
  const existingIndex = aliases.findIndex(
    (entry) => entry.from.toLowerCase() === alias.from.toLowerCase(),
  );
  if (existingIndex >= 0) {
    aliases[existingIndex] = {
      from: aliases[existingIndex].from,
      to: alias.to,
    };
    return;
  }
  aliases.push(alias);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function stampSnapshot(
  snapshot: STTVocabularySnapshot,
  options: STTVocabularyStoreOptions,
): STTVocabularySnapshot {
  return {
    updated_at: (options.now?.() ?? new Date()).toISOString(),
    prompt_terms: snapshot.prompt_terms,
    aliases: snapshot.aliases,
  };
}

function writeSnapshot(
  path: string,
  snapshot: STTVocabularySnapshot,
  changed: boolean,
): STTVocabularyMutationResult {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmpPath = join(
    dir,
    `.${basename(path)}.${process.pid}.${Date.now()}.${Math.random()
      .toString(16)
      .slice(2)}.tmp`,
  );
  let fd: number | null = null;
  try {
    fd = openSync(
      tmpPath,
      constants.O_CREAT | constants.O_TRUNC | constants.O_WRONLY,
      0o600,
    );
    writeFileSync(fd, JSON.stringify(snapshot, null, 2) + "\n", "utf8");
    fsyncSync(fd);
    closeSync(fd);
    fd = null;
    renameSync(tmpPath, path);
    fsyncDirectory(dir);
    return { ...snapshot, changed };
  } catch (error) {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {}
    }
    try {
      unlinkSync(tmpPath);
    } catch {}
    throw error;
  }
}

function withVocabularyLock<T>(
  path: string,
  options: STTVocabularyStoreOptions,
  fn: () => T,
): T {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const lockPath = `${path}.lock`;
  const lockFd = acquireLock(lockPath, options);
  try {
    return fn();
  } finally {
    try {
      closeSync(lockFd);
    } catch {}
    try {
      unlinkSync(lockPath);
    } catch {}
  }
}

function acquireLock(
  lockPath: string,
  options: STTVocabularyStoreOptions,
): number {
  const timeoutMs = options.lockTimeoutMs ?? DEFAULT_LOCK_TIMEOUT_MS;
  const staleLockMs = options.staleLockMs ?? DEFAULT_STALE_LOCK_MS;
  const deadline = Date.now() + timeoutMs;

  while (true) {
    try {
      const fd = openSync(
        lockPath,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
        0o600,
      );
      writeFileSync(
        fd,
        JSON.stringify({
          pid: process.pid,
          created_at: new Date().toISOString(),
        }),
        "utf8",
      );
      fsyncSync(fd);
      return fd;
    } catch (error) {
      if (!isErrno(error, "EEXIST")) throw error;
      if (isStaleLock(lockPath, staleLockMs)) {
        try {
          unlinkSync(lockPath);
        } catch {}
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error("timed out waiting for vocabulary lock");
      }
      sleepSync(25);
    }
  }
}

function isStaleLock(lockPath: string, staleLockMs: number): boolean {
  try {
    return Date.now() - statSync(lockPath).mtimeMs > staleLockMs;
  } catch {
    return false;
  }
}

function fsyncDirectory(dir: string): void {
  const fd = openSync(dir, constants.O_RDONLY);
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function isErrno(error: unknown, code: string): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as Error & { code?: string }).code === code
  );
}
