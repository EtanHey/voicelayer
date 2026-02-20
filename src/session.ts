/**
 * Session lifecycle manager.
 *
 * Handles creating, saving, and loading QA and discovery sessions.
 * Sessions are JSON files stored in ~/.golems/sessions/.
 * Reports/briefs are markdown files in ~/.golems/reports/ or ~/.golems/briefs/.
 */

import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { join } from "path";
import type { QASession } from "./schemas/checklist";
import type { DiscoverySession } from "./schemas/discovery";
import { renderReport } from "./report";
import { renderBrief } from "./brief";

// Read HOME at call time (not module load) to support test overrides
function getDir(subdir: string): string {
  const home = process.env.HOME || "/tmp";
  return join(home, ".golems", subdir);
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
  return JSON.parse(readFileSync(path, "utf-8"));
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
  return JSON.parse(readFileSync(path, "utf-8"));
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
