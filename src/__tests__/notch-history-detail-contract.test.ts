import { expect, test } from "bun:test";

const source = (file: string) =>
  Bun.file(new URL(`../../flow-bar/Sources/VoiceBarUI/${file}.swift`, import.meta.url)).text();

test("both notch History surfaces get the player fenced by Ask", async () => {
  const bar = await source("BarView");
  const state = await source("VoiceState");
  const server = await Bun.file(
    new URL("../../flow-bar/Sources/VoiceBar/SocketServer.swift", import.meta.url),
  ).text();
  expect(bar).toContain("playback: state.historyPlayback");
  expect(bar).not.toContain("historyPlayback = SettingsAudioPlayback.system()");
  expect(state).toContain("historyPlayback.setVoiceOwner(");
  expect(server).toMatch(/state\.handleEvent\(gateEvent\)[\s\S]+?"cmd": "history_playback_ready"/);
});

test("a category keeps its list mounted while showing a detail", async () => {
  const categories = await source("NotchHistoryCategories");
  const page = categories.slice(categories.indexOf("private func page(_ scope:"),
    categories.indexOf("private var liveDetail"));
  expect(page).toMatch(/ZStack[^\n]*\{\s*list\(scope\)/);
  expect(page).toContain(".accessibilityHidden(detail != nil)");
  expect(page).toContain(".allowsHitTesting(detail == nil)");
});

test("a failed Play has a visible detail notice", async () => {
  const detail = await source("NotchHistoryDetail");
  expect(detail).toContain("actions.playback?.failureMessage");
  expect(detail).toMatch(/if let failureMessage[^\n]*\{\s*Text\(failureMessage\)/);
});
