import { describe, it, expect } from "bun:test";
import {
  createDiscoverySession,
  addChecklistItem,
  updateChecklistItem,
  addRedFlag,
  getOpenQuestions,
  finalizeDiscoverySession,
} from "../schemas/discovery";

describe("discovery schema", () => {
  it("createDiscoverySession returns valid session", () => {
    const session = createDiscoverySession("Acme Corp");

    expect(session.session.mode).toBe("discovery");
    expect(session.session.client_name).toBe("Acme Corp");
    expect(session.session.status).toBe("in_progress");
    expect(session.session.id).toMatch(/^discovery-\d{4}-\d{2}-\d{2}-\d{4}$/);
    expect(session.checklist).toEqual([]);
    expect(session.red_flags).toEqual([]);
  });

  it("addChecklistItem adds and auto-increments IDs", () => {
    const session = createDiscoverySession("Client");

    addChecklistItem(session, {
      category: "scope",
      question: "What type of project?",
      status: "answered",
      answer: "E-commerce site",
      follow_ups: [],
    });
    addChecklistItem(session, {
      category: "budget",
      question: "Budget range?",
      status: "unanswered",
      answer: "",
      follow_ups: ["Get exact number in follow-up email"],
    });

    expect(session.checklist.length).toBe(2);
    expect(session.checklist[0].id).toBe(1);
    expect(session.checklist[1].id).toBe(2);
  });

  it("updateChecklistItem updates status and answer", () => {
    const session = createDiscoverySession("Client");
    addChecklistItem(session, {
      category: "scope",
      question: "What type?",
      status: "unanswered",
      answer: "",
      follow_ups: [],
    });

    const updated = updateChecklistItem(session, 1, {
      status: "answered",
      answer: "Mobile app",
    });

    expect(updated).not.toBeNull();
    expect(updated!.status).toBe("answered");
    expect(updated!.answer).toBe("Mobile app");
  });

  it("updateChecklistItem returns null for unknown ID", () => {
    const session = createDiscoverySession("Client");
    const result = updateChecklistItem(session, 999, { status: "answered" });
    expect(result).toBeNull();
  });

  it("addRedFlag adds flags with timestamp", () => {
    const session = createDiscoverySession("Client");

    addRedFlag(session, {
      flag: "Client wants it by next week",
      severity: "high",
      suggestion: "Clarify scope — unrealistic timeline",
    });

    expect(session.red_flags.length).toBe(1);
    expect(session.red_flags[0].severity).toBe("high");
    expect(session.red_flags[0].timestamp).toBeDefined();
  });

  it("getOpenQuestions returns unanswered and partial items", () => {
    const session = createDiscoverySession("Client");

    addChecklistItem(session, {
      category: "scope",
      question: "What type?",
      status: "answered",
      answer: "Website",
      follow_ups: [],
    });
    addChecklistItem(session, {
      category: "budget",
      question: "Budget?",
      status: "unanswered",
      answer: "",
      follow_ups: [],
    });
    addChecklistItem(session, {
      category: "technical",
      question: "Stack?",
      status: "partial",
      answer: "React maybe",
      follow_ups: ["Confirm with CTO"],
    });

    const open = getOpenQuestions(session);
    expect(open.length).toBe(2);
    expect(open[0].question).toBe("Budget?");
    expect(open[1].question).toBe("Stack?");
  });

  it("finalizeDiscoverySession populates open questions from checklist", () => {
    const session = createDiscoverySession("Client");

    addChecklistItem(session, {
      category: "scope",
      question: "What type?",
      status: "answered",
      answer: "Website",
      follow_ups: [],
    });
    addChecklistItem(session, {
      category: "budget",
      question: "Budget range?",
      status: "unanswered",
      answer: "",
      follow_ups: [],
    });
    addChecklistItem(session, {
      category: "technical",
      question: "Hosting preference?",
      status: "answered",
      answer: "AWS",
      follow_ups: ["Which region?"],
    });

    finalizeDiscoverySession(session);

    expect(session.session.status).toBe("completed");
    expect(session.session.ended).toBeDefined();
    // Open questions: 1 unanswered + 1 follow-up
    expect(session.brief.open_questions).toContain("Budget range?");
    expect(session.brief.open_questions).toContain("Which region?");
  });
});
