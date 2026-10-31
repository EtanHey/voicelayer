/** Internal opt-in copy intent; deliberately absent from the wire protocol. */
export type ConversationUtterance = {
  agent: { readonly id: string; readonly name: string };
} & (
  | { phase: "FIRST_CONTACT" | "IMMEDIATE_FOLLOWUP" | "RETURN_AFTER_WORK" }
  | { phase: "ACK_AFTER_USER"; work: "work" | "lookup" }
);

export interface ConversationSpeakerState {
  heardAgentId?: string;
  pending?: symbol;
}

type Copy = { text: string; agentId: string };
export type ConversationUtterancePlan = Copy & (
  | { kind: "speech"; responseRequired: false }
  | { kind: "admitted-ask-required"; phase: "RETURN_AFTER_WORK"; responseRequired: true }
);

/** Formatting never commits delivered-contact state or changes supplied body text. */
export function prepareConversationUtterance(
  body: string,
  intent: ConversationUtterance,
  state: ConversationSpeakerState,
): ConversationUtterancePlan {
  const returning = intent.phase === "RETURN_AFTER_WORK";
  const intro = returning || state.heardAgentId !== intent.agent.id;
  const copy = intent.phase === "ACK_AFTER_USER"
    ? intent.work === "work" ? "OK, I'm on it." : "OK, I'm looking it up."
    : body;
  const text = `${intro ? `${intent.agent.name} here. ` : ""}${copy}`;
  const agentId = intent.agent.id;
  return returning
    ? { kind: "admitted-ask-required", phase: "RETURN_AFTER_WORK", responseRequired: true, text, agentId }
    : { kind: "speech", responseRequired: false, text, agentId };
}

/** Future gate: admitted Ask / atomic speech+Ask with P4/P5 ownership and End fences. */
export class AdmittedConversationAskRequired extends Error {
  constructor(readonly plan: Extract<ConversationUtterancePlan, { kind: "admitted-ask-required" }>) {
    super("ADMITTED_CONVERSATION_ASK: work-return requires an admitted atomic adapter; bare SDK speak/listen is forbidden");
  }
}
