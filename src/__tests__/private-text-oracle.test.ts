import { expect, test } from "bun:test";
import { expectTailKept } from "./setup/private-text-oracle";

// Public canary standing in for a private transcript that fails the oracle.
const CANARY = "T3_PUBLIC_CANARY_9d41 wait so you are not on main this is";

test("a failing private-text oracle prints labels and counts, never the transcript", () => {
  let failure: unknown;
  try { expectTailKept(CANARY); } catch (error) { failure = error; }
  expect(failure).toBeDefined();
  const printed = [String(failure), (failure as Error).stack ?? "", Bun.inspect(failure)].join("\n");
  expect(printed.includes("endsWithFinalWord")).toBe(true); // the failure is still diagnosable
  expect(printed.includes("T3_PUBLIC_CANARY_9d41")).toBe(false);
  expect(printed.includes("not on main")).toBe(false);
});

test("the oracle passes a kept tail", () => {
  expect(() => expectTailKept("Public words. This is very confusing.")).not.toThrow();
});
