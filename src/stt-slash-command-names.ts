/**
 * Command and skill names installed on this machine, for spoken slash commands.
 *
 * Directory and file NAMES only, read-only, never logged. A root is read one
 * level deep (a skill is a folder holding SKILL.md, a command is a `.md` file);
 * a plain sub-folder of a root is read one more level for namespaced `.md`
 * commands (`commands/frontend/component.md` -> `/component`). Symlinked
 * folders are recognised as skills but never walked, so a symlink cycle cannot
 * recurse, and no filesystem error ever leaves this module: a root that cannot
 * be read gives no names.
 *
 * The names are loaded once per root, on first use, then refreshed in the
 * background: at most every five minutes, or sooner when the root's own mtime
 * changes (one wrapped stat per take). A take never waits for a refresh; it uses
 * the previous set, and a failed refresh keeps it.
 */
import { readdirSync, statSync, type Dirent } from "fs";
import { readdir, stat } from "fs/promises";
import { join } from "path";

export const SLASH_COMMAND_NAMES_REFRESH_MS = 5 * 60 * 1000;
const SUPPORT_DIRS = new Set(["assets", "references"]);

type EntryKind = "dir" | "file" | "symlink" | "other";
type Entry = { name: string; kind: EntryKind };
type FsOp =
  | { op: "list"; path: string; root: boolean }
  | { op: "exists"; path: string }
  | { op: "isDir"; path: string };

export function commandNameFromMarkdownEntry(name: string): string | null {
  if (!name || name.startsWith(".")) return null;
  if (!name.endsWith(".md")) return null;
  if (name.toLowerCase() === "readme.md") return null;
  const commandName = name.slice(0, -3);
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(commandName)) return null;
  if (commandName.toLowerCase() === "skill") return null;
  return commandName;
}

export function commandNameFromDirectoryEntry(name: string): string | null {
  if (!name || name.startsWith(".")) return null;
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(name)) return null;
  if (name.toLowerCase() === "skill") return null;
  return name;
}

// Written once over abstract operations so the first (synchronous) load and the
// background (asynchronous) refresh read a root identically.
function* scanRoot(root: string): Generator<FsOp, string[], unknown> {
  const listing = (yield { op: "list", path: root, root: true }) as Entry[] | null;
  const names: string[] = [];
  const add = (name: string | null) => {
    if (name && !names.includes(`/${name}`)) names.push(`/${name}`);
  };
  for (const entry of listing ?? []) {
    if (entry.name.startsWith(".")) continue;
    const path = join(root, entry.name);
    const isDir = entry.kind === "dir" ||
      (entry.kind === "symlink" && ((yield { op: "isDir", path }) as boolean));
    if (isDir) {
      if (SUPPORT_DIRS.has(entry.name.toLowerCase())) continue;
      if ((yield { op: "exists", path: join(path, "SKILL.md") }) as boolean) {
        add(commandNameFromDirectoryEntry(entry.name));
        continue;
      }
      // Never walk into a symlinked folder: that is where a cycle would start.
      if (entry.kind !== "dir") continue;
      const inner = (yield { op: "list", path, root: false }) as Entry[] | null;
      for (const child of inner ?? []) {
        if (child.kind === "file" || child.kind === "symlink") add(commandNameFromMarkdownEntry(child.name));
      }
      continue;
    }
    if (entry.kind === "file" || entry.kind === "symlink") add(commandNameFromMarkdownEntry(entry.name));
  }
  return names;
}

function toEntries(entries: Dirent[]): Entry[] {
  return entries
    .map((entry): Entry => ({
      name: String(entry.name),
      kind: entry.isDirectory() ? "dir" : entry.isFile() ? "file" : entry.isSymbolicLink() ? "symlink" : "other",
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function listFailed(error: unknown, root: boolean): null {
  // A missing root is an honest "no names"; any other failure of a root is an
  // error the caller handles (first load: no names; refresh: keep the old set).
  if (root && (error as NodeJS.ErrnoException)?.code !== "ENOENT") throw error;
  return null;
}

function runSync(op: FsOp): unknown {
  if (op.op === "list") {
    try {
      return toEntries(readdirSync(op.path, { withFileTypes: true }));
    } catch (error) {
      return listFailed(error, op.root);
    }
  }
  try {
    const info = statSync(op.path);
    return op.op === "isDir" ? info.isDirectory() : true;
  } catch {
    return false;
  }
}

async function runAsync(op: FsOp): Promise<unknown> {
  if (op.op === "list") {
    try {
      return toEntries(await readdir(op.path, { withFileTypes: true }));
    } catch (error) {
      return listFailed(error, op.root);
    }
  }
  try {
    const info = await stat(op.path);
    return op.op === "isDir" ? info.isDirectory() : true;
  } catch {
    return false;
  }
}

/** Throws when the root exists but cannot be read; a missing root gives []. */
export function readSlashCommandRootSync(root: string): string[] {
  const scan = scanRoot(root);
  let step = scan.next();
  while (!step.done) step = scan.next(runSync(step.value));
  return step.value;
}

/** Rejects when the root exists but cannot be read; a missing root gives []. */
export async function readSlashCommandRoot(root: string): Promise<string[]> {
  const scan = scanRoot(root);
  let step = scan.next();
  while (!step.done) step = scan.next(await runAsync(step.value));
  return step.value;
}

export function slashCommandRootMtimeMs(root: string): number | null {
  try {
    return statSync(root).mtimeMs;
  } catch {
    return null;
  }
}

export type SlashCommandNameCacheDeps = {
  now: () => number;
  rootMtimeMs: (root: string) => number | null;
  readRootSync: (root: string) => string[];
  readRoot: (root: string) => Promise<string[]>;
  refreshMs?: number;
};

type RootState = {
  names: string[];
  mtimeMs: number | null;
  loadedAtMs: number;
  refreshing: boolean;
};

export function createSlashCommandNameCache(deps: SlashCommandNameCacheDeps) {
  const refreshMs = deps.refreshMs ?? SLASH_COMMAND_NAMES_REFRESH_MS;
  const states = new Map<string, RootState>();
  const inFlight = new Set<Promise<void>>();
  const mtimeOf = (root: string) => {
    try {
      return deps.rootMtimeMs(root);
    } catch {
      return null;
    }
  };

  const namesForRoot = (root: string): string[] => {
    const state = states.get(root);
    if (!state) {
      const mtimeMs = mtimeOf(root);
      let names: string[] = [];
      try {
        names = deps.readRootSync(root);
      } catch {
        names = [];
      }
      states.set(root, { names, mtimeMs, loadedAtMs: deps.now(), refreshing: false });
      return names;
    }
    if (state.refreshing) return state.names;
    const mtimeMs = mtimeOf(root);
    if (mtimeMs === state.mtimeMs && deps.now() - state.loadedAtMs < refreshMs) return state.names;

    state.refreshing = true;
    const settle = (names: string[] | null) => {
      if (names) state.names = names;
      state.mtimeMs = mtimeMs;
      state.loadedAtMs = deps.now();
      state.refreshing = false;
    };
    const refresh: Promise<void> = Promise.resolve()
      .then(() => deps.readRoot(root))
      .then((names) => settle(names), () => settle(null))
      .finally(() => inFlight.delete(refresh));
    inFlight.add(refresh);
    return state.names;
  };

  return {
    /** Never throws and never waits for a refresh. */
    names(roots: readonly string[]): string[] {
      const names = new Set<string>();
      for (const root of roots) for (const name of namesForRoot(root)) names.add(name);
      return [...names];
    },
    /** For tests: resolves when every background refresh has finished. */
    async settled(): Promise<void> {
      while (inFlight.size) await Promise.all([...inFlight]);
    },
  };
}

const installedSlashCommandNames = createSlashCommandNameCache({
  now: Date.now,
  rootMtimeMs: slashCommandRootMtimeMs,
  readRootSync: readSlashCommandRootSync,
  readRoot: readSlashCommandRoot,
});

export function loadInstalledSlashCommandNames(roots: readonly string[]): string[] {
  return installedSlashCommandNames.names(roots);
}
