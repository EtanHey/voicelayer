import { describe, it, expect } from "bun:test";
import {
  createSession,
  addPage,
  addCheck,
  finalizeSession,
} from "../schemas/checklist";

describe("checklist schema", () => {
  it("createSession returns a valid empty session", () => {
    const session = createSession("https://example.com");

    expect(session.session.mode).toBe("qa");
    expect(session.session.url).toBe("https://example.com");
    expect(session.session.status).toBe("in_progress");
    expect(session.session.id).toMatch(/^qa-\d{4}-\d{2}-\d{2}-\d{4}$/);
    expect(session.pages).toEqual([]);
    expect(session.summary.total_checks).toBe(0);
  });

  it("addPage adds a page to the session", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/", "Homepage");

    expect(session.pages.length).toBe(1);
    expect(page.url).toBe("/");
    expect(page.name).toBe("Homepage");
    expect(page.checks).toEqual([]);
  });

  it("addCheck adds a check and updates counters", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/", "Homepage");

    addCheck(session, page, {
      category: "accessibility",
      question: "Do inputs have labels?",
      status: "pass",
      severity: "high",
      notes: "All inputs labeled",
      screenshot: null,
    });

    expect(page.checks.length).toBe(1);
    expect(page.checks[0].id).toBe(1);
    expect(session.summary.total_checks).toBe(1);
    expect(session.summary.passed).toBe(1);
  });

  it("addCheck tracks failed checks", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/", "Homepage");

    addCheck(session, page, {
      category: "responsive",
      question: "Layout correct at 375px?",
      status: "fail",
      severity: "high",
      notes: "Nav overlaps logo on mobile",
      screenshot: null,
    });

    expect(session.summary.failed).toBe(1);
    expect(session.session.issues_found).toBe(1);
  });

  it("addCheck tracks critical issues separately", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/login", "Login");

    addCheck(session, page, {
      category: "interaction",
      question: "Does form validation work?",
      status: "fail",
      severity: "critical",
      notes: "Login form submits without password",
      screenshot: null,
    });

    expect(session.summary.critical_issues).toEqual([
      "Login form submits without password",
    ]);
  });

  it("addCheck increments IDs sequentially", () => {
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
    addCheck(session, page, {
      category: "seo",
      question: "Meta title?",
      status: "pass",
      severity: "medium",
      notes: "Good title",
      screenshot: null,
    });

    expect(page.checks[0].id).toBe(1);
    expect(page.checks[1].id).toBe(2);
  });

  it("finalizeSession sets end time and completed status", () => {
    const session = createSession("https://example.com");
    addPage(session, "/", "Homepage");
    addPage(session, "/about", "About");

    finalizeSession(session);

    expect(session.session.status).toBe("completed");
    expect(session.session.ended).toBeDefined();
    expect(session.session.pages_checked).toBe(2);
  });

  it("skipped checks are counted", () => {
    const session = createSession("https://example.com");
    const page = addPage(session, "/", "Homepage");

    addCheck(session, page, {
      category: "performance",
      question: "Lazy loading?",
      status: "skip",
      severity: "low",
      notes: "No images on this page",
      screenshot: null,
    });

    expect(session.summary.skipped).toBe(1);
    expect(session.summary.total_checks).toBe(1);
  });
});
