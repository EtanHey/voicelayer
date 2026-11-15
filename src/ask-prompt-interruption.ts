/** Only the Ask that still owns its prompt may yield to F5. Listening is never interrupted here. */
let prompt: { cancel(): void; released: Promise<void> } | undefined;
export function registerAskPrompt(cancel: () => void, released: Promise<void>): () => void {
  const owner = { cancel, released };
  prompt = owner;
  return () => { if (prompt === owner) prompt = undefined; };
}
export function interruptAskPromptForDictation(): Promise<void> | undefined {
  const owner = prompt;
  if (!owner) return;
  owner.cancel();
  return owner.released;
}

/** Read-only preflight: refusal must not consume the Ask. */
export function hasInterruptibleAskPrompt(): boolean { return prompt !== undefined; }
