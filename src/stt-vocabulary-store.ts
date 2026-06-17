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

export interface STTDictionaryEntry {
  canonical: string;
  variants: string[];
}

export interface STTVocabularySnapshot {
  updated_at: string | null;
  entries: STTDictionaryEntry[];
}

export interface STTVocabularyWarning {
  code: "near_duplicate_canonical";
  canonical: string;
  existing: string;
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
  warnings?: STTVocabularyWarning[];
};

interface RawVocabularySnapshot {
  updated_at?: unknown;
  entries?: unknown;
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
    const warnings = nearDuplicateWarnings(snapshot.entries, normalized.to);
    upsertEntryVariant(snapshot.entries, normalized.to, normalized.from);
    return withWarnings(
      writeSnapshot(path, stampSnapshot(snapshot, options), true),
      warnings,
    );
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
    const warnings = nearDuplicateWarnings(snapshot.entries, normalized);
    upsertEntry(snapshot.entries, normalized);
    return withWarnings(
      writeSnapshot(path, stampSnapshot(snapshot, options), true),
      warnings,
    );
  });
}

export function removePromptTerm(
  term: string,
  options: STTVocabularyStoreOptions = {},
): STTVocabularyMutationResult {
  const normalized = validateText(term, "term");
  const path = getSTTVocabularyPath(options);
  return withVocabularyLock(path, options, () => {
    const snapshot = readSnapshot(path);
    const entries = snapshot.entries.filter(
      (entry) => entry.canonical.toLowerCase() !== normalized.toLowerCase(),
    );
    const removed = entries.length !== snapshot.entries.length;
    if (!removed) {
      return { ...snapshot, changed: false, removed: false };
    }
    snapshot.entries = entries;
    return {
      ...writeSnapshot(path, stampSnapshot(snapshot, options), true),
      removed,
    };
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
    const normalizedKey = aliasKey(normalizedFrom);
    let removed = false;
    for (const entry of snapshot.entries) {
      const nextVariants = entry.variants.filter(
        (variant) => aliasKey(variant) !== normalizedKey,
      );
      if (nextVariants.length !== entry.variants.length) {
        removed = true;
        entry.variants = nextVariants;
      }
    }
    if (!removed) {
      return { ...snapshot, changed: false, removed: false };
    }
    return {
      ...writeSnapshot(path, stampSnapshot(snapshot, options), true),
      removed,
    };
  });
}

function validateAlias(alias: STTVocabularyAlias): STTVocabularyAlias {
  const from = validateAliasSource(alias.from);
  const to = validateText(alias.to, "to");
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
    return { updated_at: null, entries: [] };
  }

  const parsed = JSON.parse(
    readFileSync(path, "utf8"),
  ) as RawVocabularySnapshot;
  return normalizeSnapshot(parsed);
}

function normalizeSnapshot(
  parsed: RawVocabularySnapshot,
): STTVocabularySnapshot {
  const entries = Array.isArray(parsed.entries)
    ? normalizeEntries(parsed.entries)
    : migrateLegacySnapshot(parsed);
  return {
    updated_at:
      typeof parsed.updated_at === "string" && parsed.updated_at.trim()
        ? parsed.updated_at
        : null,
    entries,
  };
}

function migrateLegacySnapshot(parsed: RawVocabularySnapshot): STTDictionaryEntry[] {
  const entries: STTDictionaryEntry[] = [];
  if (Array.isArray(parsed.prompt_terms)) {
    for (const term of parsed.prompt_terms) {
      if (isNonEmptyString(term)) {
        upsertEntry(entries, term.trim());
      }
    }
  }
  if (Array.isArray(parsed.aliases)) {
    for (const entry of parsed.aliases) {
      if (!entry || typeof entry !== "object") continue;
      const { from, to } = entry as Partial<STTVocabularyAlias>;
      if (!isNonEmptyString(from) || !isNonEmptyString(to)) continue;
      const normalizedFrom = from.trim();
      if (isUnsafeDynamicAliasSource(normalizedFrom)) continue;
      appendEntryVariant(entries, to.trim(), normalizedFrom);
    }
  }
  return entries;
}

function normalizeEntries(values: unknown[]): STTDictionaryEntry[] {
  const entries: STTDictionaryEntry[] = [];
  for (const value of values) {
    if (!value || typeof value !== "object") continue;
    const { canonical, variants } = value as Partial<STTDictionaryEntry>;
    if (!isNonEmptyString(canonical)) continue;
    upsertEntry(entries, canonical.trim());
    if (!Array.isArray(variants)) continue;
    for (const variant of variants) {
      if (!isNonEmptyString(variant)) continue;
      const normalizedVariant = variant.trim();
      if (isUnsafeDynamicAliasSource(normalizedVariant)) continue;
      appendEntryVariant(entries, canonical.trim(), normalizedVariant);
    }
  }
  return entries;
}

function upsertEntry(entries: STTDictionaryEntry[], canonical: string): void {
  const existing = entries.find(
    (entry) => entry.canonical.toLowerCase() === canonical.toLowerCase(),
  );
  if (existing) return;
  entries.push({ canonical, variants: [] });
}

function upsertEntryVariant(
  entries: STTDictionaryEntry[],
  canonical: string,
  variant: string,
): void {
  upsertEntry(entries, canonical);
  const entry = entries.find(
    (candidate) => candidate.canonical.toLowerCase() === canonical.toLowerCase(),
  );
  if (!entry) return;

  const variantKey = aliasKey(variant);
  if (variantKey === aliasKey(entry.canonical)) return;

  for (let index = entries.length - 1; index >= 0; index--) {
    const candidate = entries[index];
    const existingVariant = candidate.variants.find(
      (item) => aliasKey(item) === variantKey,
    );
    if (!existingVariant) continue;
    candidate.variants = candidate.variants.filter(
      (item) => aliasKey(item) !== variantKey,
    );
    if (!entry.variants.some((item) => aliasKey(item) === variantKey)) {
      entry.variants.push(existingVariant);
    }
    return;
  }
  entry.variants.push(variant);
}

function appendEntryVariant(
  entries: STTDictionaryEntry[],
  canonical: string,
  variant: string,
): void {
  upsertEntry(entries, canonical);
  const entry = entries.find(
    (candidate) => candidate.canonical.toLowerCase() === canonical.toLowerCase(),
  );
  if (!entry) return;
  if (aliasKey(variant) === aliasKey(entry.canonical)) return;
  if (entry.variants.includes(variant)) return;
  entry.variants.push(variant);
}

export function vocabularyAliasesFromEntries(
  entries: STTDictionaryEntry[],
): STTVocabularyAlias[] {
  return entries.flatMap((entry) =>
    entry.variants.map((variant) => ({
      from: variant,
      to: entry.canonical,
    })),
  );
}

export function canonicalTermsFromEntries(entries: STTDictionaryEntry[]): string[] {
  return entries.map((entry) => entry.canonical);
}

export function aliasKey(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

export function sameOrNearDuplicate(left: string, right: string): boolean {
  if (left === right) return true;
  if (aliasKey(left) === aliasKey(right)) return true;
  if (Math.min(left.length, right.length) < 5) return false;
  const leftKey = aliasKey(left);
  const rightKey = aliasKey(right);
  const denominator = Math.max(leftKey.length, rightKey.length, 1);
  return levenshtein(leftKey, rightKey) / denominator <= 0.16;
}

function nearDuplicateWarnings(
  entries: STTDictionaryEntry[],
  canonical: string,
): STTVocabularyWarning[] {
  const existing = entries.find(
    (entry) =>
      entry.canonical.toLowerCase() !== canonical.toLowerCase() &&
      sameOrNearDuplicate(entry.canonical, canonical),
  );
  return existing
    ? [
        {
          code: "near_duplicate_canonical",
          canonical,
          existing: existing.canonical,
        },
      ]
    : [];
}

function withWarnings<T extends STTVocabularyMutationResult>(
  result: T,
  warnings: STTVocabularyWarning[],
): T {
  if (warnings.length === 0) return result;
  return { ...result, warnings };
}

function levenshtein(left: string, right: string): number {
  if (left === right) return 0;
  if (!left) return right.length;
  if (!right) return left.length;
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 0; leftIndex < left.length; leftIndex++) {
    const current = [leftIndex + 1];
    for (let rightIndex = 0; rightIndex < right.length; rightIndex++) {
      const insertCost = current[rightIndex] + 1;
      const deleteCost = previous[rightIndex + 1] + 1;
      const replaceCost =
        previous[rightIndex] + (left[leftIndex] === right[rightIndex] ? 0 : 1);
      current.push(Math.min(insertCost, deleteCost, replaceCost));
    }
    previous = current;
  }
  return previous[previous.length - 1];
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
    entries: snapshot.entries,
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
