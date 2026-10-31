import { expect, test } from "bun:test";
import * as fs from "fs";
import { speechReasons, speechStates } from "../speech-state";
import type { SpeakLifecycle } from "../speak-archive-store";

// Settings › History › Speech maps every reason to display copy in Swift. These checks fail when a reason or
// status is added here without that mapping, so History can never fall back to printing a raw code.
const archiveStatuses = ["received", "preparing", "playing", "paused", "completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"] as const;
type UnlistedArchiveStatus = Exclude<SpeakLifecycle["status"], typeof archiveStatuses[number]>;
const everyArchiveStatusListed: [UnlistedArchiveStatus] extends [never] ? true : false = true;

const fixture = JSON.parse(fs.readFileSync(new URL("../../flow-bar/Tests/Fixtures/speech-reasons.json", import.meta.url), "utf8"));
const swift = fs.readFileSync(new URL("../../flow-bar/Sources/VoiceBarUI/SettingsSpeechReasonCopy.swift", import.meta.url), "utf8");

test("the Swift copy table's fixture lists every speech state, archive status and reason", () => {
  expect(everyArchiveStatusListed).toBe(true);
  expect(fixture).toEqual({ states: [...speechStates], archive_statuses: [...archiveStatuses], reasons: [...speechReasons] });
});

test("the Swift copy table maps every speech reason", () => {
  const known = swift.match(/static let knownReasons: Set<String> = \[([^\]]*)\]/)?.[1];
  expect(known).toBeDefined();
  expect([...known!.matchAll(/"([A-Z_]+)"/g)].map((match) => match[1]).sort()).toEqual([...speechReasons].sort());
  const mapping = swift.slice(swift.indexOf("static func sentence("));
  for (const reason of speechReasons) expect(mapping).toContain(`"${reason}"`);
});
