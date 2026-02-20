/**
 * QA Session checklist schema.
 *
 * Defines the structure for tracking QA findings per page, per viewport,
 * with severity levels and category grouping.
 */

export type CheckStatus = "pass" | "fail" | "skip" | "na";
export type Severity = "critical" | "high" | "medium" | "low" | "enhancement";
export type QACategory =
  | "accessibility"
  | "responsive"
  | "content"
  | "interaction"
  | "performance"
  | "seo";

export interface QACheck {
  id: number;
  category: QACategory;
  question: string;
  status: CheckStatus;
  severity: Severity;
  notes: string;
  screenshot: string | null;
  timestamp: string;
}

export interface QAPage {
  url: string;
  name: string;
  viewports_tested: string[];
  checks: QACheck[];
}

export interface QASession {
  session: {
    id: string;
    mode: "qa";
    url: string;
    started: string;
    ended?: string;
    status: "in_progress" | "completed" | "aborted";
    pages_checked: number;
    issues_found: number;
  };
  pages: QAPage[];
  summary: {
    total_checks: number;
    passed: number;
    failed: number;
    skipped: number;
    critical_issues: string[];
  };
}

/**
 * Create a new empty QA session.
 */
export function createSession(url: string): QASession {
  const now = new Date();
  const dateStr = now.toISOString().slice(0, 10);
  const id = `qa-${dateStr}-${String(now.getTime()).slice(-4)}`;

  return {
    session: {
      id,
      mode: "qa",
      url,
      started: now.toISOString(),
      status: "in_progress",
      pages_checked: 0,
      issues_found: 0,
    },
    pages: [],
    summary: {
      total_checks: 0,
      passed: 0,
      failed: 0,
      skipped: 0,
      critical_issues: [],
    },
  };
}

/**
 * Add a page to the session.
 */
export function addPage(
  session: QASession,
  url: string,
  name: string
): QAPage {
  const page: QAPage = {
    url,
    name,
    viewports_tested: [],
    checks: [],
  };
  session.pages.push(page);
  return page;
}

/**
 * Add a check to a page and update session counters.
 */
export function addCheck(
  session: QASession,
  page: QAPage,
  check: Omit<QACheck, "id" | "timestamp">
): QACheck {
  const fullCheck: QACheck = {
    ...check,
    id: page.checks.length + 1,
    timestamp: new Date().toISOString(),
  };

  page.checks.push(fullCheck);
  session.summary.total_checks++;

  if (check.status === "pass") session.summary.passed++;
  if (check.status === "fail") {
    session.summary.failed++;
    session.session.issues_found++;
    if (check.severity === "critical") {
      session.summary.critical_issues.push(check.notes);
    }
  }
  if (check.status === "skip") session.summary.skipped++;

  return fullCheck;
}

/**
 * Finalize a session — set end time and status.
 */
export function finalizeSession(session: QASession): void {
  session.session.ended = new Date().toISOString();
  session.session.status = "completed";
  session.session.pages_checked = session.pages.length;
}
