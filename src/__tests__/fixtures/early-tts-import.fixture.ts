import { expect, it } from "bun:test";
import * as tts from "../../tts";

// TESTISO2: loads tts.ts (and its pronunciation binding) before pronunciation.test.ts runs, as any
// alphabetically earlier test file importing tts does in CI's Linux file order.
it("pronunciation isolation: tts is loaded first", () => { expect(typeof tts.speakText).toBe("function"); });
