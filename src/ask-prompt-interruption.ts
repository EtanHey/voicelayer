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
  // Bound refusal while physical exit remains unconfirmed.
  // Refusal leaves the physical-exit fence and the prompt registration intact.
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Ask prompt exit unconfirmed")), 2000);
    owner.released.then(() => {
      clearTimeout(timer);
      if (prompt === owner) reject(new Error("Ask prompt exit unconfirmed"));
      else resolve();
    }, error => { clearTimeout(timer); reject(error); });
  });
}

/** Read-only preflight: refusal must not consume the Ask. */
export function hasInterruptibleAskPrompt(): boolean { return prompt !== undefined; }
