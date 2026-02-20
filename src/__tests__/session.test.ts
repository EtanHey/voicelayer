import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, rmSync, mkdirSync } from "fs";
import { join } from "path";

// Override HOME to use temp dir for tests
const TEST_HOME = "/tmp/voicelayer-test-home";
process.env.HOME = TEST_HOME;

import {
  saveQASession,
  loadQASession,
  generateQAReport,
  saveDiscoverySession,
  loadDiscoverySession,
  generateDiscoveryBrief,
} from "../session";
import { createSession, addPage, addCheck, finalizeSession } from "../schemas/checklist";
import {
  createDiscoverySession,
  addChecklistItem,
  addRedFlag,
  finalizeDiscoverySession,
} from "../schemas/discovery";

describe("session lifecycle", () => {
  beforeEach(() => {
    // Clean test home
    if (existsSync(TEST_HOME)) {
      rmSync(TEST_HOME, { recursive: true });
    }
    mkdirSync(TEST_HOME, { recursive: true });
  });

  afterEach(() => {
    if (existsSync(TEST_HOME)) {
      rmSync(TEST_HOME, { recursive: true });
    }
  });

  it("saves and loads a QA session", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/", "Homepage");
    addCheck(session, page, {
      category: "content",
      question: "Any lorem ipsum?",
      status: "pass",
      severity: "high",
      notes: "Clean",
      screenshot: null,
    });

    const savedPath = saveQASession(session);
    expect(existsSync(savedPath)).toBe(true);

    const loaded = loadQASession(session.session.id);
    expect(loaded).not.toBeNull();
    expect(loaded!.session.url).toBe("https://example.com");
    expect(loaded!.pages.length).toBe(1);
  });

  it("returns null for unknown session ID", () => {
    const loaded = loadQASession("nonexistent-id");
    expect(loaded).toBeNull();
  });

  it("generates QA report markdown file", () => {
    const session = createSession("https://example.com");
    addPage(session, "/", "Homepage");
    finalizeSession(session);

    const reportPath = generateQAReport(session);
    expect(existsSync(reportPath)).toBe(true);
    expect(reportPath).toContain(".voicelayer/reports/");
    expect(reportPath).toEndWith(".md");
  });

  it("saves and loads a discovery session", () => {
    const session = createDiscoverySession("Test Client");
    addChecklistItem(session, {
      category: "scope",
      question: "What type?",
      status: "answered",
      answer: "Website",
      follow_ups: [],
    });

    const savedPath = saveDiscoverySession(session);
    expect(existsSync(savedPath)).toBe(true);

    const loaded = loadDiscoverySession(session.session.id);
    expect(loaded).not.toBeNull();
    expect(loaded!.session.client_name).toBe("Test Client");
  });

  it("generates discovery brief markdown file", () => {
    const session = createDiscoverySession("Brief Client");
    session.brief.project_type = "Website";
    finalizeDiscoverySession(session);

    const briefPath = generateDiscoveryBrief(session);
    expect(existsSync(briefPath)).toBe(true);
    expect(briefPath).toContain(".voicelayer/briefs/");
    expect(briefPath).toEndWith(".md");
  });

  it("creates directories automatically", () => {
    const sessionsDir = join(TEST_HOME, ".voicelayer", "sessions");
    expect(existsSync(sessionsDir)).toBe(false);

    const session = createSession("https://example.com");
    saveQASession(session);

    expect(existsSync(sessionsDir)).toBe(true);
  });
});
