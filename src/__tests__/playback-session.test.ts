/**
 * Lane B (2.4): the PlaybackSession engine against formal/playback-session. Each trace replays a
 * TLA+ behaviour; the corruption table proves the runtime checker names each invariant; the random
 * walk calls every operation in arbitrary order and asserts no invariant ever breaks.
 */
import { describe, expect, it } from "bun:test";
import {
  ASK_PROMPT_ID,
  PLAYBACK_SPEEDS,
  PlaybackSessionEngine,
  nextPlaybackSpeed,
  resolvePauseCursorMs,
  type PlaybackSession,
} from "../playback/session";

function playing(engine: PlaybackSessionEngine, id: string, words = 10) {
  expect(engine.begin(id, "read", words)).toMatchObject({ ok: true, state: "preparing" });
  expect(engine.ready(id)).toMatchObject({ ok: true });
  expect(engine.get(id)!.state).toBe("playing");
}

function healthy(engine: PlaybackSessionEngine) {
  expect(engine.violations()).toEqual([]);
}

describe("ResumeExact: Etan's 'pause sometimes jumps back'", () => {
  it("resume lands on the paused word, and a second pause after it on the word heard then", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.word("r1", 4);
    expect(engine.pause("r1", 4)).toMatchObject({ ok: true, word: 4 });
    engine.playerExited("r1");
    expect(engine.resume("r1")).toMatchObject({ ok: true, word: 4 });
    expect(engine.tele).toBe(4);
    engine.ready("r1");
    engine.word("r1", 6);
    engine.teleprompter(6);
    expect(engine.pause("r1", 6)).toMatchObject({ word: 6 });
    healthy(engine);
  });

  it("a pause before the player exists (CLICK2) resumes at the word it was preparing", () => {
    const engine = new PlaybackSessionEngine();
    engine.begin("r1", "read", 10);
    expect(engine.pause("r1", 0)).toMatchObject({ ok: true, word: 0 });
    expect(engine.resume("r1")).toMatchObject({ word: 0 });
    healthy(engine);
  });

  it("an f5 pause converts to a user pause without moving the word", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.pause("r1", 3, "f5");
    expect(engine.pause("r1", 0, "user")).toMatchObject({ ok: true, word: 3 });
    expect(engine.get("r1")!.pauseOwner).toBe("user");
  });
});

describe("AskParksOne: voice_ask over a read", () => {
  function ask(engine: PlaybackSessionEngine) {
    expect(engine.canStartPrompt()).toBe(engine.players.size === 0 && engine.exiting.size === 0);
    for (const id of [...engine.exiting]) engine.playerExited(id);
    expect(engine.askPromptStart()).toMatchObject({ ok: true });
    expect(engine.askPromptEnd()).toMatchObject({ ok: true });
    engine.playerExited(ASK_PROMPT_ID);
    expect(engine.micOpen()).toMatchObject({ ok: true });
    expect(engine.captureEnd("answer")).toMatchObject({ ok: true });
    expect(engine.askRestore()).toMatchObject({ ok: false, reason: "recorder still running" });
    engine.recorderExit();
  }

  it("parks a playing read at its word and restores it playing from the same word", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    expect(engine.askBegin(5)).toMatchObject({ ok: true, id: "r1", word: 5, state: "parked" });
    ask(engine);
    expect(engine.askRestore()).toEqual({ ok: true, restored: { id: "r1", state: "preparing", word: 5 } });
    expect(engine.ready("r1")).toMatchObject({ ok: true, word: 5 });
    healthy(engine);
  });

  it("keeps a user-paused read paused at its stored word (the driver word cannot move it)", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.pause("r1", 7);
    engine.playerExited("r1");
    engine.askBegin(0);
    ask(engine);
    expect(engine.askRestore()).toEqual({ ok: true, restored: { id: "r1", state: "paused", word: 7 } });
    healthy(engine);
  });

  it("two asks back to back over one read: each parks and restores the same word", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(3);
    ask(engine);
    engine.askRestore();
    // The second ask lands while the restored read is still preparing its player.
    expect(engine.get("r1")!.state).toBe("preparing");
    expect(engine.askBegin()).toMatchObject({ ok: true, word: 3 });
    ask(engine);
    expect(engine.askRestore()).toMatchObject({ restored: { id: "r1", word: 3 } });
    engine.ready("r1");
    expect(engine.get("r1")!.cursor).toBe(3);
    healthy(engine);
  });

  it("an ask that fails before its prompt still restores the read", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(2);
    expect(engine.askAbort("fail")).toMatchObject({ ok: true });
    expect(engine.askRestore()).toMatchObject({ restored: { id: "r1", state: "preparing", word: 2 } });
    healthy(engine);
  });

  it("Stop during the ask ends the ask, never the parked read: it comes back paused", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(4);
    engine.playerExited("r1");
    engine.askPromptStart();
    engine.stopAll();
    expect(engine.ask).toBe("closing");
    engine.playerExited(ASK_PROMPT_ID);
    expect(engine.askRestore()).toMatchObject({ restored: { id: "r1", state: "paused", word: 4 } });
    healthy(engine);
  });

  it("Esc during the ask cancels the ask; the read is restored", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(1);
    expect(engine.esc()).toMatchObject({ ok: true });
    expect(engine.askRestore()).toMatchObject({ restored: { id: "r1" } });
  });

  it("no new read starts while an ask is in progress", () => {
    const engine = new PlaybackSessionEngine();
    engine.askBegin();
    expect(engine.begin("r2", "read", 3)).toEqual({ ok: false, reason: "ask in progress" });
  });
});

describe("OneAudible and MicExclusive", () => {
  it("the prompt waits for the parked read's player to exit; the mic waits for the prompt's", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(1);
    expect(engine.canStartPrompt()).toBe(false);
    expect(engine.askPromptStart()).toEqual({ ok: false, reason: "speaker busy" });
    engine.playerExited("r1");
    engine.askPromptStart();
    engine.askPromptEnd();
    expect(engine.micOpen()).toEqual({ ok: false, reason: "speaker busy" });
    engine.playerExited(ASK_PROMPT_ID);
    expect(engine.micOpen()).toMatchObject({ ok: true });
    healthy(engine);
  });

  it("a restored read never starts while the recorder is still alive", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.askBegin(1);
    engine.playerExited("r1");
    engine.askPromptSkipped();
    engine.micOpen();
    engine.captureEnd("timeout");
    expect(engine.askRestore()).toMatchObject({ ok: false });
    expect(engine.canStart("r1")).toBe(false);
    engine.recorderExit();
    engine.askRestore();
    expect(engine.canStart("r1")).toBe(true);
  });

  it("a next read waits for the previous player to be reaped", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.end("r1");
    engine.begin("r2", "read", 4);
    expect(engine.ready("r2")).toEqual({ ok: false, reason: "speaker busy" });
    engine.playerExited("r1");
    expect(engine.ready("r2")).toMatchObject({ ok: true });
  });
});

describe("NoZombie, OneLiveSession, previous read, seek, Esc", () => {
  it("a preparation cancelled by Esc never starts its player", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.pause("r1", 2);
    engine.playerExited("r1");
    engine.resume("r1");
    expect(engine.esc("r1")).toMatchObject({ ok: true });
    expect(engine.ready("r1")).toMatchObject({ ok: false });
    expect(engine.players.size).toBe(0);
    healthy(engine);
  });

  it("previous read holds the read on screen at its word; it returns paused there after the replay", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.word("r1", 3);
    engine.teleprompter(3, "r1");
    expect(engine.previous()).toMatchObject({ ok: true, id: "r1", word: 3, state: "queued" });
    expect(engine.live()).toBeUndefined();
    expect(engine.begin("r1", "read", 10)).toEqual({ ok: false, reason: "held by previous read" });
    engine.playerExited("r1");
    // The replay is its own session from word 0.
    playing(engine, "replay-1", 6);
    expect(engine.previousReturn()).toEqual({ ok: false, reason: "previous read still on screen" });
    engine.word("replay-1", 6);
    engine.end("replay-1");
    expect(engine.previousReturn()).toMatchObject({ ok: true, id: "r1", word: 3, state: "paused" });
    expect(engine.tele).toBe(3);
    engine.playerExited("replay-1");
    expect(engine.resume("r1")).toMatchObject({ word: 3 });
    healthy(engine);
  });

  it("a held read superseded by a new read ends", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.previous();
    engine.dropPrevious();
    expect(engine.get("r1")!.state).toBe("ended");
  });

  it("previous read with nothing on screen is refused by the engine (the driver replays without a hold)", () => {
    const engine = new PlaybackSessionEngine();
    expect(engine.previous()).toEqual({ ok: false, reason: "nothing on screen" });
  });

  it("a seek lands on its word and the teleprompter follows", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.word("r1", 5);
    engine.teleprompter(5);
    engine.seek("r1", 4);
    engine.playerExited("r1");
    expect(engine.seekDone("r1")).toMatchObject({ word: 4 });
    expect(engine.tele).toBe(4);
    engine.ready("r1");
    healthy(engine);
  });

  it("Esc stops a resumed read", () => {
    const engine = new PlaybackSessionEngine();
    playing(engine, "r1");
    engine.pause("r1", 3);
    engine.playerExited("r1");
    engine.resume("r1");
    engine.ready("r1");
    expect(engine.esc()).toMatchObject({ ok: true, id: "r1" });
    expect(engine.get("r1")!.state).toBe("ended");
    expect(engine.live()).toBeUndefined();
  });
});

describe("the runtime checker names every invariant (the implementation's mutants)", () => {
  const cases: Array<[string, (engine: PlaybackSessionEngine) => void]> = [
    ["ResumeExact", engine => { playing(engine, "r1"); engine.pause("r1", 4); engine.resume("r1");
      (engine.get("r1") as PlaybackSession).resumedAt = 0; }],
    ["OneAudible", engine => { playing(engine, "r1"); engine.players.add("r2"); }],
    ["AskParksOne", engine => { playing(engine, "r1"); engine.askBegin(1); engine.ask = "none"; }],
    ["MicExclusive", engine => { playing(engine, "r1"); engine.recorder = true; }],
    ["TeleTracksAudio", engine => { playing(engine, "r1"); engine.word("r1", 5); engine.teleprompter(0); }],
    ["OneLiveSession", engine => { playing(engine, "r1"); (engine as any).sessions.set("r2", { id: "r2", kind: "read", state: "paused", cursor: 0, wordCount: 1, generation: 0 }); }],
    ["NoZombie", engine => { playing(engine, "r1"); engine.esc("r1"); engine.players.add("r1"); engine.exiting.clear(); }],
  ];
  for (const [invariant, corrupt] of cases) {
    it(`${invariant} is reported`, () => {
      const engine = new PlaybackSessionEngine();
      corrupt(engine);
      expect(engine.violations().some(line => line.startsWith(`${invariant}:`))).toBe(true);
    });
  }
});

describe("random walk: no operation order breaks an invariant", () => {
  it("120,000 random steps (uniform and weighted) over two reads, asks, seeks, stops and previous reads", () => {
    let seed = 0x2b4;
    // High bits only: an LCG's low bits cycle with a tiny period (random(2) would just alternate).
    const random = (n: number) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >>> 16) % n; };
    const ids = ["r1", "r2"];
    for (let walk = 0; walk < 2000; walk++) {
      const weighted = walk % 2 === 1;
      const engine = new PlaybackSessionEngine({ maxLog: 8 });
      for (let step = 0; step < 60; step++) {
        const id = ids[random(2)];
        const ops = [
          () => engine.begin(id, "read", 4),
          () => engine.ready(id),
          () => { const live = engine.get(id); if (live?.state === "playing" && engine.tele === live.cursor) engine.word(id, live.cursor + 1); },
          () => { const live = engine.get(id); if (live) engine.teleprompter(live.cursor, id); },
          () => engine.end(id),
          () => engine.playerExited([...engine.players, ...engine.exiting][0] ?? id),
          () => engine.pause(id, engine.get(id)?.cursor ?? 0, random(2) ? "user" : "f5"),
          () => engine.resume(id),
          () => engine.seek(id, random(4)),
          () => engine.seekDone(id),
          () => engine.esc(random(2) ? id : undefined),
          () => engine.previous(),
          () => engine.previousReturn(),
          () => engine.askBegin(random(3) ? undefined : engine.get(id)?.cursor),
          () => engine.askPromptStart(),
          () => engine.askPromptEnd(),
          () => engine.askPromptSkipped(),
          () => engine.micOpen(),
          () => engine.captureEnd("answer"),
          () => engine.askAbort("cancel"),
          () => engine.recorderExit(),
          () => engine.askRestore(),
          () => engine.stopAll(),
        ];
        // Weighted toward the play/pause/resume/word edges so deep behaviours (resume after a
        // mid-read pause, an ask over a resumed read) are reached often, not by luck.
        // Odd walks are weighted, even walks uniform: together they reach both shallow and deep orders.
        const weights = weighted ? [1, 4, 6, 6, 1, 4, 3, 4, 1, 2, 1, 1, 1, 1, 2, 2, 1, 2, 2, 1, 2, 2, 1] : ops.map(() => 1);
        let pick = random(weights.reduce((a, b) => a + b, 0)), index = 0;
        while (pick >= weights[index]) pick -= weights[index++];
        ops[index]();
        const violations = engine.violations();
        if (violations.length) throw new Error(`walk ${walk} step ${step}: ${violations.join("; ")}\n${JSON.stringify(engine.log)}`);
      }
    }
  });
});

describe("pause cursor resolution", () => {
  it.each([
    [{ clientMs: 0, daemonMs: 4200 }, 4200, "daemon"],
    [{ clientMs: -3500, daemonMs: 6500 }, 6500, "daemon"],
    [{ clientMs: 3900, daemonMs: 4300 }, 3900, "client"],
    [{ clientMs: 4200, daemonMs: 0 }, 4200, "client"],
    [{ clientMs: 9000, daemonMs: 1000, durationMs: 5000 }, 5000, "client"],
    [{ daemonMs: 2500 }, 2500, "daemon"],
    [{ clientMs: 1200 }, 1200, "client"],
    [{}, 0, "none"],
    [{ clientMs: Number.NaN, daemonMs: 800 }, 800, "daemon"],
  ] as const)("%j → %d (%s)", (input, cursorMs, source) => {
    expect(resolvePauseCursorMs(input)).toEqual({ cursorMs, source });
  });
});

describe("speed steps", () => {
  it("1× is a real step and the control cycles through every speed", () => {
    expect(PLAYBACK_SPEEDS).toContain(1);
    const seen = [1];
    let speed: number = 1;
    for (let i = 0; i < PLAYBACK_SPEEDS.length - 1; i++) { speed = nextPlaybackSpeed(speed); seen.push(speed); }
    expect(new Set(seen).size).toBe(PLAYBACK_SPEEDS.length);
    expect(nextPlaybackSpeed(speed)).toBe(1);
  });
});
