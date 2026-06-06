import { describe, expect, it } from "bun:test";
import * as server from "./server";
import {
  buildInterpretMessages,
  createVoiceReviewApp,
  parseInterpretDecision,
  type ReviewCluster,
} from "./server";

const naturalCluster: ReviewCluster = {
  cluster_id: "diagnosis-flag:cantaloupe",
  category: "diagnosis-flag",
  stem: "cantaloupe",
  size: 3,
  members: [
    {
      id: "company",
      name: "Cantaloupe",
      type: "company",
      chunks: 13,
    },
    {
      id: "project",
      name: "Cantaloupe",
      type: "project",
      chunks: 4,
    },
    {
      id: "person",
      name: "Cantaloupe",
      type: "person",
      chunks: 2,
    },
  ],
};

type StubNode = {
  className: string;
  disabled: boolean;
  hidden: boolean;
  innerHTML: string;
  scrollHeight: number;
  scrollTop: number;
  src: string;
  textContent: string;
  value: string;
  currentTime: number;
  paused: boolean;
  readyState: number;
  children: StubNode[];
  classList: {
    add: (name: string) => void;
    remove: (name: string) => void;
    toggle: (name: string, force?: boolean) => void;
  };
  style: Record<string, unknown> & {
    setProperty: (name: string, value: string) => void;
  };
  addEventListener: () => void;
  removeEventListener: () => void;
  removeAttribute: (name: string) => void;
  appendChild: (child: StubNode) => void;
  load: () => void;
  pause: () => void;
  play: () => Promise<void>;
};

function createStubNode(id: string): StubNode {
  const node: StubNode = {
    className: "",
    disabled: false,
    hidden: false,
    innerHTML: "",
    scrollHeight: 0,
    scrollTop: 0,
    src: "",
    textContent: "",
    value: "",
    currentTime: 0,
    paused: true,
    readyState: 0,
    children: [] as StubNode[],
    classList: {
      add(name: string) {
        const classes = new Set(node.className.split(/\s+/).filter(Boolean));
        classes.add(name);
        node.className = [...classes].join(" ");
      },
      remove(name: string) {
        const classes = new Set(node.className.split(/\s+/).filter(Boolean));
        classes.delete(name);
        node.className = [...classes].join(" ");
      },
      toggle(name: string, force?: boolean) {
        const enabled = force ?? !node.className.split(/\s+/).includes(name);
        if (enabled) node.classList.add(name);
        else node.classList.remove(name);
      },
    },
    style: {
      setProperty(name: string, value: string) {
        node.style[name] = value;
      },
    } as StubNode["style"],
    addEventListener() {},
    removeEventListener() {},
    removeAttribute(name: string) {
      if (name === "src") node.src = "";
    },
    appendChild(child: StubNode) {
      node.children.push(child);
      node.innerHTML += child.innerHTML || child.textContent;
      node.scrollHeight = node.children.length;
    },
    load() {
      node.readyState = 0;
    },
    pause() {
      node.paused = true;
    },
    play: async () => {
      node.paused = false;
    },
  };
  if (id === "category") node.value = "diagnosis-flag";
  if (id === "ttsVoice") node.value = "en-US-GuyNeural";
  if (id === "ttsRate") node.value = "-8";
  return node;
}

async function createPageHarness(options: {
  category?: string;
  nextResponse?: unknown;
  nextError?: Error;
}) {
  const app = createVoiceReviewApp();
  const response = await app.fetch(new Request("http://localhost/"));
  const html = await response.text();
  const script = html.match(/<script type="module">([\s\S]*?)<\/script>/)?.[1];
  if (!script) throw new Error("page script not found");

  const nodes = new Map<string, StubNode>();
  const getNode = (id: string) => {
    let node = nodes.get(id);
    if (!node) {
      node = createStubNode(id);
      nodes.set(id, node);
    }
    return node;
  };
  getNode("category").value = options.category || "diagnosis-flag";

  const document = {
    getElementById: getNode,
    createElement: (tag: string) => createStubNode(tag),
  };
  const fetchCalls: string[] = [];
  const fetchImpl = async (path: string) => {
    fetchCalls.push(path);
    if (options.nextError) throw options.nextError;
    return new Response(JSON.stringify(options.nextResponse), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const speechCalls: string[] = [];
  const window = {
    speechSynthesis: {
      cancel() {
        speechCalls.push("cancel");
      },
      speak() {
        speechCalls.push("speak");
      },
    },
  };
  class SpeechSynthesisUtteranceStub {
    onend: (() => void) | null = null;
    onerror: (() => void) | null = null;

    constructor(public text: string) {}
  }
  const urlStub = {
    revokeObjectURL() {},
  };
  const executableScript = script.replace(
    /^\s*import\s+\*\s+as\s+ort\s+from\s+"\/vendor\/onnxruntime-web\/ort\.wasm\.min\.mjs";\s*/,
    "",
  );
  const api = new Function(
    "document",
    "fetch",
    "window",
    "SpeechSynthesisUtterance",
    "URL",
    `${executableScript}\nreturn { loadNext, showLegFailure, endSession };`,
  )(
    document,
    fetchImpl,
    window,
    SpeechSynthesisUtteranceStub,
    urlStub,
  ) as {
    loadNext: (play: boolean) => Promise<void>;
    showLegFailure: (message: string) => void;
    endSession: () => Promise<void>;
  };

  return { api, fetchCalls, nodes, node: getNode, speechCalls };
}

describe("VoiceReview natural conversation redesign", () => {
  it("builds an update-first interpret prompt with per-member deltas", () => {
    const messages = buildInterpretMessages({
      transcript: "the person is not relevant, I still need company versus project",
      cluster: naturalCluster,
      understanding: {
        member_updates: {
          company: "undecided",
          project: "undecided",
          person: "undecided",
        },
        notes: [],
      },
    } as never);

    expect(messages[0].content).toContain(
      "Allowed action values: update|merge|keep|mixed|skip|question",
    );
    expect(messages[0].content).toContain("member_updates");
    expect(messages[0].content).toContain("remaining_question");
    expect(messages[0].content).toContain(
      "Only emit merge, keep, mixed, or skip when every member is resolved",
    );
    expect(messages[1].content).toContain("Current understanding:");
    expect(messages[1].content).toContain("person: undecided");
  });

  it("parses additive update deltas without forcing a terminal decision", () => {
    const decision = parseInterpretDecision(
      JSON.stringify({
        action: "update",
        member_updates: {
          person: "irrelevant",
          company: "undecided",
          project: "undecided",
        },
        remaining_question:
          "Should company and project merge, or stay separate?",
        note: "the person is not relevant",
      }),
      naturalCluster,
      "the person is not relevant",
    ) as any;

    expect(decision).toEqual({
      action: "update",
      member_updates: {
        person: "irrelevant",
        company: "undecided",
        project: "undecided",
      },
      remaining_question: "Should company and project merge, or stay separate?",
      note: "the person is not relevant",
      source: "voice",
    });
  });

  it("accumulates partial member resolutions into one terminal mixed decision", () => {
    expect(typeof (server as any).createUnderstandingState).toBe("function");
    expect(typeof (server as any).applyUnderstandingDelta).toBe("function");

    const state = (server as any).createUnderstandingState(naturalCluster);
    const first = (server as any).applyUnderstandingDelta(
      state,
      {
        action: "update",
        member_updates: {
          person: "irrelevant",
          company: "merge",
        },
        remaining_question: "What about the project?",
        note: "person is irrelevant and company is the real entity",
        source: "voice",
      },
      naturalCluster,
    );

    expect(first.terminalDecision).toBeNull();
    expect(first.state.member_updates).toMatchObject({
      person: "irrelevant",
      company: "merge",
      project: "undecided",
    });

    const second = (server as any).applyUnderstandingDelta(
      first.state,
      {
        action: "update",
        member_updates: {
          project: "keep",
        },
        note: "keep the project separate",
        source: "voice",
      },
      naturalCluster,
    );

    expect(second.terminalDecision).toEqual({
      action: "mixed",
      members: {
        company: "merge",
        project: "keep",
        person: "prune",
      },
      note:
        "person is irrelevant and company is the real entity\nkeep the project separate",
      source: "voice",
    });
  });

  it("advances always-listening turn states with subtle settling and paused barge-in", () => {
    expect(typeof (server as any).createTurnTakingState).toBe("function");
    expect(typeof (server as any).advanceTurnTakingFrame).toBe("function");

    let state = (server as any).createTurnTakingState({
      settleMs: 1200,
      frameMs: 100,
      playbackBargeInFrames: 3,
    });

    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.hasSpeechInTurn).toBe(true);

    for (let index = 0; index < 5; index += 1) {
      state = (server as any).advanceTurnTakingFrame(state, { speech: false });
    }
    expect(state.phase).toBe("SETTLING");
    expect(state.settleProgress).toBeCloseTo(5 / 12, 3);
    expect(state.showSettlingRing).toBe(false);

    for (let index = 0; index < 3; index += 1) {
      state = (server as any).advanceTurnTakingFrame(state, { speech: false });
    }
    expect(state.phase).toBe("SETTLING");
    expect(state.showSettlingRing).toBe(true);

    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.settleElapsedMs).toBe(0);

    state.phase = "SPEAKING";
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.pausePlayback).toBe(false);
    state = (server as any).advanceTurnTakingFrame(state, { speech: true });
    expect(state.phase).toBe("LISTENING");
    expect(state.pausePlayback).toBe(true);
  });

  it("splits interrupted agent speech into spoken and unspoken context", () => {
    expect(typeof (server as any).splitInterruptedSpeech).toBe("function");

    const split = (server as any).splitInterruptedSpeech(
      "First sentence gives context. Second sentence triggers the interruption.",
      [
        { offset_ms: 0, duration_ms: 200, text: "First" },
        { offset_ms: 250, duration_ms: 200, text: "sentence" },
        { offset_ms: 500, duration_ms: 200, text: "gives" },
        { offset_ms: 750, duration_ms: 200, text: "context." },
        { offset_ms: 1100, duration_ms: 200, text: "Second" },
      ],
      900,
    );

    expect(split).toEqual({
      agent_speech_spoken_so_far: "First sentence gives context.",
      agent_speech_unspoken_remainder:
        "Second sentence triggers the interruption.",
      interrupted_at_ms: 900,
    });
  });

  it("prepares browser Silero VAD tensors with 64 samples of context plus 512 audio samples", () => {
    expect(typeof (server as any).createSileroVadInput).toBe("function");

    const context = new Float32Array(64).fill(-0.25);
    const chunk = new Float32Array(512);
    for (let index = 0; index < chunk.length; index += 1) {
      chunk[index] = index / chunk.length;
    }

    const prepared = (server as any).createSileroVadInput(chunk, context);
    expect(prepared.dims).toEqual([1, 576]);
    expect(prepared.input).toHaveLength(576);
    expect(prepared.input[0]).toBe(-0.25);
    expect(prepared.input[64]).toBe(0);
    expect(prepared.nextContext).toEqual(chunk.slice(448));
  });

  it("serves one-button always-listening UI with Silero VAD, fallback labeling, and visible offline states", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect((html.match(/<button\b/g) || [])).toHaveLength(1);
    expect(html).toContain("Start session");
    expect(html).toContain("End session");
    expect(html).toContain("echoCancellation: true");
    expect(html).toContain("onnxruntime-web");
    expect(html).toContain("/models/silero_vad.onnx");
    expect(html).toContain("basic mode");
    expect(html).toContain("brain offline — retrying");
    expect(html).toContain("LISTENING");
    expect(html).toContain("SETTLING");
    expect(html).toContain("THINKING");
    expect(html).toContain("SPEAKING");
    expect(html).not.toContain("Tap Record");
    expect(html).not.toContain("tap Record");
  });

  it("does not suppress VAD barge-in while the previous turn is still processing", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).not.toContain("if (!sessionActive || processingTurn) return;");
    expect(html).toContain("if (processingTurn && !turnState.pausePlayback)");
    expect(html).toContain("agent_speech_spoken_so_far");
    expect(html).toContain("agent_speech_unspoken_remainder");
    expect(html).toContain("interrupted_at_ms");
    expect(html).toContain("paused utterance");
    expect(html).toContain("resume");
  });

  it("clears paused interruption context before resumed audio can make the next turn stale", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const clearPaused = html.slice(
      html.indexOf("function clearPausedUtterance()"),
      html.indexOf("async function resumePausedUtterance()"),
    );
    const resumePaused = html.slice(
      html.indexOf("async function resumePausedUtterance()"),
      html.indexOf("async function loadNext(play)"),
    );

    expect(clearPaused).toContain("pendingInterruption = null;");
    expect(resumePaused).toContain("pendingInterruption = null;");
    expect(resumePaused.indexOf("pendingInterruption = null;")).toBeLessThan(
      resumePaused.indexOf("await playAudioUrl"),
    );
  });

  it("hard-suppresses VAD while browser system speech is active", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const handleVad = html.slice(
      html.indexOf("function handleVadFrame(speech)"),
      html.indexOf("function beginTurnCapture()"),
    );
    const speakSystem = html.slice(
      html.indexOf("function speakSystemText(text)"),
      html.indexOf("async function ensureMicOpen()"),
    );

    expect(html).toContain("let systemSpeechActive = false;");
    expect(handleVad).toContain("if (systemSpeechActive) return;");
    expect(speakSystem).toContain("systemSpeechActive = true;");
    expect(speakSystem).toContain("systemSpeechActive = false;");
    expect(speakSystem).toContain('turnState.phase = "SPEAKING";');
  });

  it("serves a simple chat column with collapsed evidence and no prior/current turn label soup", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain('id="turnLog"');
    expect(html).toContain('id="evidencePanel"');
    expect(html).toContain("<summary>Evidence</summary>");
    expect(html).not.toContain('id="evidencePanel" open');
    expect(html).not.toContain("Prior turn");
    expect(html).not.toContain("Current turn");
    expect(html).toContain("speakAgent(answer, { log: false })");
  });

  it("sanitizes spoken text separately from displayed structured data", () => {
    expect(typeof (server as any).humanizeSpokenText).toBe("function");

    const spoken = (server as any).humanizeSpokenText(
      "### Evidence\n- rt-a93575c2-1234 chunk 17 type=user_message: Merge into `kg_entity_chunks`.\nShown: <strong>raw</strong>",
    );

    expect(spoken).not.toContain("rt-a93575c2");
    expect(spoken).not.toContain("chunk 17");
    expect(spoken).not.toContain("type=user_message");
    expect(spoken).not.toContain("###");
    expect(spoken).not.toContain("<strong>");
    expect(spoken).toBe(
      "Evidence. Merge into kg entity chunks. Shown: raw",
    );

    const narrated = (server as any).humanizeSpokenText(
      "Members:\n- FooBar (project, 2 chunks)\n- Foo Bar (project, 1 chunks)\n- FooBar CLI (tool, 1 chunks)",
    );

    expect(narrated).toBe(
      "Three entries: two project entries with similar names, and one tool entry.",
    );
  });

  it("lets the reviewer configure edge-tts voice and cadence from the page", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain('id="ttsVoice"');
    expect(html).toContain("en-US-GuyNeural");
    expect(html).toContain('id="ttsRate"');
    expect(html).toContain('type="range"');
    expect(html).toContain("rate: selectedTtsRate()");
    expect(html).toContain("voice: selectedTtsVoice()");
  });

  it("serves the Silero model file to the browser", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(
      new Request("http://localhost/models/silero_vad.onnx"),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe(
      "application/octet-stream",
    );
    expect(Number(response.headers.get("content-length"))).toBeGreaterThan(
      2_000_000,
    );
  });

  it("reports LiteRT health failure visibly instead of leaving a dead placeholder", async () => {
    const app = createVoiceReviewApp({
      fetchImpl: async () => {
        throw new Error("connect ECONNREFUSED 127.0.0.1:9379");
      },
    });

    const response = await app.fetch(new Request("http://localhost/api/health"));
    const body = await response.json();

    expect(response.status).toBe(503);
    expect(body).toMatchObject({
      ok: false,
      message: "brain offline — retrying",
      legs: {
        litert: {
          ok: false,
        },
      },
    });
  });

  it("renders explicit queue terminal and fetch error states during page bootstrap", async () => {
    const complete = await createPageHarness({
      nextResponse: {
        cluster: null,
        queue_state: {
          kind: "complete",
          category: "diagnosis-flag",
          decided: 7,
          message: "All items in this queue are complete 🎉 7 decided.",
        },
      },
    });
    await complete.api.loadNext(false);

    expect(complete.fetchCalls).toEqual(["/api/next?category=diagnosis-flag"]);
    expect(complete.node("clusterId").textContent).toBe("Queue complete");
    expect(complete.node("stem").textContent).toBe("diagnosis-flag");
    expect(complete.node("members").innerHTML).toContain("7 decided");
    expect(complete.node("openQuestion").textContent).toBe(
      "All items in this queue are complete 🎉 7 decided.",
    );
    expect(complete.node("decision").textContent).toBe(
      "All items in this queue are complete 🎉 7 decided.",
    );
    expect(complete.node("status").textContent).toBe(
      "All items in this queue are complete 🎉 7 decided.",
    );

    const empty = await createPageHarness({
      category: "sep-variants",
      nextResponse: {
        cluster: null,
        queue_state: {
          kind: "empty",
          category: "sep-variants",
          decided: 0,
          message: "No items found for category sep-variants.",
        },
      },
    });
    await empty.api.loadNext(false);

    expect(empty.node("clusterId").textContent).toBe("No items found");
    expect(empty.node("stem").textContent).toBe("sep-variants");
    expect(empty.node("members").innerHTML).toContain("No queued items");
    expect(empty.node("openQuestion").textContent).toBe(
      "No items found for category sep-variants.",
    );
    expect(empty.node("status").textContent).toBe(
      "No items found for category sep-variants.",
    );

    const statsError = await createPageHarness({
      nextResponse: {
        cluster: null,
        queue_state: {
          kind: "error",
          category: "diagnosis-flag",
          decided: 0,
          message: "Stats unavailable: stale decisions reference missing clusters.",
        },
      },
    });
    await statsError.api.loadNext(false);

    expect(statsError.node("clusterId").textContent).toBe("Stats unavailable");
    expect(statsError.node("healthMode").textContent).toBe("stats error");
    expect(statsError.node("understandingNote").textContent).toBe(
      "Stats unavailable: stale decisions reference missing clusters.",
    );
    expect(statsError.node("status").textContent).toBe(
      "Stats unavailable: stale decisions reference missing clusters.",
    );

    const failure = await createPageHarness({
      nextError: new Error("network down"),
    });
    await failure.api.loadNext(false).catch((error) => {
      failure.api.showLegFailure(error.message);
    });

    expect(failure.node("status").textContent).toBe("network down");
    expect(failure.node("turnLog").innerHTML).toContain("network down");
  });

  it("renders stop and error state machine teardown hooks for fetches, VAD, recorder, and audio", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const runtimeState = html.slice(
      html.indexOf("let sessionActive = false;"),
      html.indexOf("function setStatus(text"),
    );
    const teardown = html.slice(
      html.indexOf("async function teardownSessionRuntime"),
      html.indexOf("async function healthCheck"),
    );
    const legFailure = html.slice(
      html.indexOf("function showLegFailure(message)"),
      html.indexOf("function isAbortError(error)"),
    );

    expect(runtimeState).toContain("let sessionAbortController = null;");
    expect(teardown).toContain("sessionAbortController.abort();");
    expect(teardown).toContain("stopActivePlayback();");
    expect(teardown).toContain("vadState.queue = [];");
    expect(teardown).toContain(
      "vadState.pendingSamples = new Float32Array(0);",
    );
    expect(teardown).toContain("processingTurn = false;");
    expect(teardown).toContain("mediaRecorder.stop();");
    expect(teardown).toContain("sessionButton.textContent = \"Start session\";");
    expect(legFailure).toContain("void teardownSessionRuntime");
    expect(legFailure).not.toContain("speakSystemText(text)");
  });

  it("gates repeated brain-offline announcements by failures, backoff, and tab visibility", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const runtimeState = html.slice(
      html.indexOf("let healthRetryTimer = null;"),
      html.indexOf("function setStatus(text"),
    );
    const healthCheck = html.slice(
      html.indexOf("async function healthCheck(silent)"),
      html.indexOf("function scheduleHealthRetry()"),
    );
    const announce = html.slice(
      html.indexOf("function canAnnounceHealthFailure()"),
      html.indexOf("function showLegFailure(message)"),
    );

    expect(html).toContain("const HEALTH_FAILURE_ANNOUNCE_THRESHOLD = 3;");
    expect(runtimeState).toContain("let healthFailureStreak = 0;");
    expect(runtimeState).toContain("let nextHealthAnnouncementAt = 0;");
    expect(runtimeState).toContain("let healthAnnouncementBackoffMs = 3000;");
    expect(healthCheck).toContain("healthFailureStreak += 1;");
    expect(healthCheck).toContain(
      "if (!silent && canAnnounceHealthFailure())",
    );
    expect(healthCheck).not.toContain(
      "if (!silent) showLegFailure(\"brain offline — retrying\");",
    );
    expect(announce).toContain(
      "healthFailureStreak < HEALTH_FAILURE_ANNOUNCE_THRESHOLD",
    );
    expect(announce).toContain('document.visibilityState !== "visible"');
    expect(announce).toContain("nextHealthAnnouncementAt = now + healthAnnouncementBackoffMs;");
    expect(announce).toContain("Math.min(60000, healthAnnouncementBackoffMs * 2)");
  });
});
