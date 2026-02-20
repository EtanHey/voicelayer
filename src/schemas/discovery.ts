/**
 * Discovery session schema.
 *
 * Tracks a client discovery call: checklist of unknowns,
 * red flags, and project brief generation.
 */

export type DiscoveryCategory =
  | "scope"
  | "technical"
  | "design"
  | "content"
  | "budget"
  | "process"
  | "competitive"
  | "red-flags";

export type ChecklistItemStatus = "answered" | "unanswered" | "partial";
export type RedFlagSeverity = "high" | "medium" | "low";

export interface ChecklistItem {
  id: number;
  category: DiscoveryCategory;
  question: string;
  status: ChecklistItemStatus;
  answer: string;
  follow_ups: string[];
  timestamp: string;
}

export interface RedFlag {
  flag: string;
  severity: RedFlagSeverity;
  suggestion: string;
  timestamp: string;
}

export interface ProjectBrief {
  project_type: string;
  estimated_complexity: "low" | "medium" | "high" | "enterprise";
  key_requirements: string[];
  open_questions: string[];
  recommended_next_steps: string[];
}

export interface DiscoverySession {
  session: {
    id: string;
    mode: "discovery";
    client_name: string;
    started: string;
    ended?: string;
    status: "in_progress" | "completed" | "aborted";
  };
  checklist: ChecklistItem[];
  red_flags: RedFlag[];
  brief: ProjectBrief;
}

/**
 * Create a new discovery session.
 */
export function createDiscoverySession(
  clientName: string
): DiscoverySession {
  const now = new Date();
  const dateStr = now.toISOString().slice(0, 10);
  const id = `discovery-${dateStr}-${String(now.getTime()).slice(-4)}`;

  return {
    session: {
      id,
      mode: "discovery",
      client_name: clientName,
      started: now.toISOString(),
      status: "in_progress",
    },
    checklist: [],
    red_flags: [],
    brief: {
      project_type: "",
      estimated_complexity: "medium",
      key_requirements: [],
      open_questions: [],
      recommended_next_steps: [],
    },
  };
}

/**
 * Add or update a checklist item.
 */
export function addChecklistItem(
  session: DiscoverySession,
  item: Omit<ChecklistItem, "id" | "timestamp">
): ChecklistItem {
  const fullItem: ChecklistItem = {
    ...item,
    id: session.checklist.length + 1,
    timestamp: new Date().toISOString(),
  };
  session.checklist.push(fullItem);
  return fullItem;
}

/**
 * Update an existing checklist item's status and answer.
 */
export function updateChecklistItem(
  session: DiscoverySession,
  itemId: number,
  update: { status?: ChecklistItemStatus; answer?: string; follow_ups?: string[] }
): ChecklistItem | null {
  const item = session.checklist.find((i) => i.id === itemId);
  if (!item) return null;

  if (update.status) item.status = update.status;
  if (update.answer) item.answer = update.answer;
  if (update.follow_ups) item.follow_ups = update.follow_ups;
  item.timestamp = new Date().toISOString();

  return item;
}

/**
 * Add a red flag to the session.
 */
export function addRedFlag(
  session: DiscoverySession,
  flag: Omit<RedFlag, "timestamp">
): RedFlag {
  const fullFlag: RedFlag = {
    ...flag,
    timestamp: new Date().toISOString(),
  };
  session.red_flags.push(fullFlag);
  return fullFlag;
}

/**
 * Get the count of unanswered/partial items.
 */
export function getOpenQuestions(session: DiscoverySession): ChecklistItem[] {
  return session.checklist.filter(
    (item) => item.status === "unanswered" || item.status === "partial"
  );
}

/**
 * Finalize a discovery session — populate brief open questions from checklist.
 */
export function finalizeDiscoverySession(session: DiscoverySession): void {
  session.session.ended = new Date().toISOString();
  session.session.status = "completed";

  // Populate open questions from unanswered checklist items
  const open = getOpenQuestions(session);
  session.brief.open_questions = open.map((item) => item.question);

  // Collect all follow-ups as additional open questions
  for (const item of session.checklist) {
    if (item.follow_ups.length > 0) {
      session.brief.open_questions.push(...item.follow_ups);
    }
  }
}
