/**
 * Session lifecycle manager.
 *
 * Handles creating, saving, and loading QA and discovery sessions.
 * Sessions are JSON files stored in ~/.voicelayer/sessions/.
 * Reports/briefs are markdown files in ~/.voicelayer/reports/ or ~/.voicelayer/briefs/.
 */

import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import type { QASession } from "./schemas/checklist";
import type { DiscoverySession } from "./schemas/discovery";
import { renderReport } from "./report";
import { renderBrief } from "./brief";

// Read HOME at call time (not module load) to support test overrides
// Use process.env.HOME first — os.homedir() may cache the value at process start
function getDir(subdir: string): string {
  const home = process.env.HOME || homedir();
  return join(home, ".voicelayer", subdir);
}

function ensureDir(dir: string): void {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

/**
 * Save a QA session to disk.
 */
export function saveQASession(session: QASession): string {
  const dir = getDir("sessions");
  ensureDir(dir);
  const path = join(dir, `${session.session.id}.json`);
  writeFileSync(path, JSON.stringify(session, null, 2));
  return path;
}

/**
 * Load a QA session from disk.
 */
export function loadQASession(sessionId: string): QASession | null {
  const path = join(getDir("sessions"), `${sessionId}.json`);
  if (!existsSync(path)) return null;
  try {
    const raw: unknown = JSON.parse(readFileSync(path, "utf-8"));
    if (!isQASession(raw)) {
      console.error(`[voicelayer] Invalid QA session shape: ${path}`);
      return null;
    }
    return raw;
  } catch {
    console.error(`[voicelayer] Failed to parse QA session: ${path}`);
    return null;
  }
}

/** Validate that parsed JSON has the shape of a QASession. */
function isQASession(raw: unknown): raw is QASession {
  if (typeof raw !== "object" || raw === null) return false;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.session !== "object" || obj.session === null) return false;
  const s = obj.session as Record<string, unknown>;
  return (
    typeof s.id === "string" &&
    s.mode === "qa" &&
    typeof s.url === "string" &&
    typeof s.started === "string" &&
    Array.isArray(obj.pages) &&
    typeof obj.summary === "object" && obj.summary !== null
  );
}

/** Validate that parsed JSON has the shape of a DiscoverySession. */
function isDiscoverySession(raw: unknown): raw is DiscoverySession {
  if (typeof raw !== "object" || raw === null) return false;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.session !== "object" || obj.session === null) return false;
  const s = obj.session as Record<string, unknown>;
  return (
    typeof s.id === "string" &&
    s.mode === "discovery" &&
    typeof s.client_name === "string" &&
    typeof s.started === "string" &&
    Array.isArray(obj.checklist) &&
    Array.isArray(obj.red_flags) &&
    typeof obj.brief === "object" && obj.brief !== null
  );
}

/**
 * Generate and save a QA report markdown.
 */
export function generateQAReport(session: QASession): string {
  const dir = getDir("reports");
  ensureDir(dir);
  const markdown = renderReport(session);
  const path = join(dir, `${session.session.id}.md`);
  writeFileSync(path, markdown);
  return path;
}

/**
 * Save a discovery session to disk.
 */
export function saveDiscoverySession(session: DiscoverySession): string {
  const dir = getDir("sessions");
  ensureDir(dir);
  const path = join(dir, `${session.session.id}.json`);
  writeFileSync(path, JSON.stringify(session, null, 2));
  return path;
}

/**
 * Load a discovery session from disk.
 */
export function loadDiscoverySession(
  sessionId: string
): DiscoverySession | null {
  const path = join(getDir("sessions"), `${sessionId}.json`);
  if (!existsSync(path)) return null;
  try {
    const raw: unknown = JSON.parse(readFileSync(path, "utf-8"));
    if (!isDiscoverySession(raw)) {
      console.error(`[voicelayer] Invalid discovery session shape: ${path}`);
      return null;
    }
    return raw;
  } catch {
    console.error(`[voicelayer] Failed to parse discovery session: ${path}`);
    return null;
  }
}

/**
 * Generate and save a discovery brief markdown.
 */
export function generateDiscoveryBrief(session: DiscoverySession): string {
  const dir = getDir("briefs");
  ensureDir(dir);
  const markdown = renderBrief(session);
  const path = join(dir, `${session.session.id}.md`);
  writeFileSync(path, markdown);
  return path;
}
