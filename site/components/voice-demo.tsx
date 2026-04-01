"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { useInView } from "framer-motion";
import { Terminal } from "./shared/terminal";

/* ─── Scenarios ─── */

const SCENARIOS = [
  {
    userPrompt: "Refactor the auth module into separate middleware",
    askQuestion:
      "Should I keep the cookie fallback for admin, or go fully stateless?",
    userResponse: "Keep cookies for admin, move JWT to its own middleware",
    lang: "en" as const,
    sttTime: "1.1s",
    agentReply: "Got it. Extracting JWT validation to jwt-middleware.ts.",
    speakText: "Done. Three files changed, all tests passing.",
    speakMode: "announce" as const,
  },
  {
    userPrompt: "Fix the Hebrew voice fallback in tts.ts",
    askQuestion:
      "he-IL voices missing from edge-tts. Fall back to en-US or try Qwen3?",
    userResponse:
      "\u05ea\u05e9\u05ea\u05de\u05e9 \u05d1 en-US \u05db fallback, \u05ea\u05d5\u05e1\u05d9\u05e3 \u05d1\u05d3\u05d9\u05e7\u05d4 \u05dc Qwen3",
    lang: "he" as const,
    sttTime: "1.3s",
    agentReply: "Adding en-US fallback with Qwen3-TTS check.",
    speakText: "Fixed. Hebrew voices fall back correctly.",
    speakMode: "brief" as const,
  },
  {
    userPrompt: "Add configurable silence timeout to voice_ask",
    askQuestion:
      "Three presets: quick, standard, thoughtful. Add custom ms option too?",
    userResponse: "No, just the three presets, keep it simple",
    lang: "en" as const,
    sttTime: "0.9s",
    agentReply: "Adding silence_mode with the three presets.",
    speakText: "Done. Schema updated, defaults to thoughtful.",
    speakMode: "consult" as const,
  },
];

const MODE_ICONS: Record<string, string> = {
  announce: "\u{1F50A}",
  brief: "\u{1F4D6}",
  consult: "\u{1F4AC}",
};

type Scenario = (typeof SCENARIOS)[number];

/* ─── Helpers ─── */

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/* ─── Equalizer ─── */

const EQ_HEIGHTS = [14, 22, 34, 28, 40, 32, 18, 36, 24, 38, 20, 30];

function Equalizer({ active }: { active: boolean }) {
  return (
    <div className="flex items-center gap-[3px] h-12" aria-hidden="true">
      {EQ_HEIGHTS.map((h, i) => (
        <div
          key={i}
          className="w-1 bg-accent rounded-sm origin-center transition-all duration-150"
          style={{
            height: active ? `${h}px` : "6px",
            opacity: active ? 1 : 0.15,
            animation: active
              ? `wave 1.2s ease-in-out infinite ${i * 0.08}s`
              : "none",
          }}
        />
      ))}
    </div>
  );
}

/* ─── Voice Demo ─── */

export function VoiceDemo() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: false, margin: "-15%" });
  const termRef = useRef<HTMLDivElement>(null);
  const transcriptRef = useRef<HTMLDivElement>(null);
  const cancelledRef = useRef(false);
  const startedRef = useRef(false);

  const [eqActive, setEqActive] = useState(false);
  const [voiceLabel, setVoiceLabel] = useState("Idle");
  const [meta, setMeta] = useState("");
  const [stt, setStt] = useState("idle");
  const [tts, setTts] = useState("idle");
  const [lang, setLang] = useState("\u2014");
  const [mode, setMode] = useState("standby");

  const appendTerm = useCallback((html: string, gap = false) => {
    if (!termRef.current) return;
    const span = document.createElement("span");
    span.className = "block" + (gap ? " mt-2" : "");
    span.innerHTML = html;
    termRef.current.appendChild(span);
    termRef.current.scrollTop = termRef.current.scrollHeight;
  }, []);

  const typeTranscript = useCallback(async (text: string, speed: number) => {
    if (!transcriptRef.current) return;
    const cursor =
      '<span class="inline-block w-0.5 h-[1em] bg-accent ml-px align-text-bottom" style="animation:blink 1s step-end infinite"></span>';
    for (let i = 0; i <= text.length; i++) {
      if (cancelledRef.current) return;
      transcriptRef.current.innerHTML = esc(text.slice(0, i)) + cursor;
      await sleep(speed + Math.random() * speed * 0.5);
    }
    await sleep(200);
    if (transcriptRef.current) transcriptRef.current.innerHTML = esc(text);
  }, []);

  const runCycle = useCallback(
    async (s: Scenario) => {
      if (!termRef.current || !transcriptRef.current) return;

      // Reset
      termRef.current.innerHTML = "";
      transcriptRef.current.innerHTML = "";
      transcriptRef.current.dir = s.lang === "he" ? "rtl" : "ltr";
      setMeta("");
      setStt("idle");
      setTts("idle");
      setLang("\u2014");
      setMode("standby");
      setVoiceLabel("Idle");
      setEqActive(false);

      await sleep(600);
      if (cancelledRef.current) return;

      // Phase 1: User prompt
      appendTerm(
        `<span class="dt-prompt">\u276F</span> <span>${esc(s.userPrompt)}</span>`,
      );
      setVoiceLabel("\u{1F50A} AI Asking");
      setMode("converse");
      setTts("edge-tts");
      setEqActive(true);
      appendTerm(
        `<span class="dt-dim">\u250C\u2500</span> <span class="dt-tool">voice_ask</span>(<span class="dt-str">"${esc(s.askQuestion)}"</span>)`,
        true,
      );
      appendTerm(`<span class="dt-dim">\u2514\u2500</span>`);
      await sleep(1500);
      if (cancelledRef.current) return;

      // Phase 2: User responds by voice
      setVoiceLabel("\u{1F3A4} Recording");
      setTts("idle");
      setStt("listening");
      await typeTranscript(s.userResponse, 35);
      await sleep(300);
      if (cancelledRef.current) return;

      // Phase 3: Transcription
      setEqActive(false);
      setVoiceLabel("Transcribing...");
      setStt("whisper.cpp");
      setLang(s.lang);
      setMeta(`whisper.cpp \u00b7 large-v3-turbo \u00b7 ${s.sttTime}`);
      await sleep(1200);
      if (cancelledRef.current) return;

      // Phase 4: voice_ask result
      setVoiceLabel("Transcribed");
      setStt("done");
      appendTerm(
        `<span class="dt-dim">\u250C\u2500</span> <span class="dt-tool">voice_ask</span> <span class="dt-dim">result</span>`,
        true,
      );
      appendTerm(
        `<span class="dt-dim">\u2502</span> <span class="dt-recording">\u{1F3A4} "${esc(s.userResponse)}"</span>`,
      );
      appendTerm(`<span class="dt-dim">\u2514\u2500</span>`);
      await sleep(800);
      if (cancelledRef.current) return;

      // Phase 5: Agent processes
      appendTerm(`<span class="dt-body">${esc(s.agentReply)}</span>`, true);
      await sleep(1500);
      if (cancelledRef.current) return;

      // Phase 6: voice_speak
      setTts("edge-tts");
      setMode(s.speakMode);
      setVoiceLabel("\u{1F50A} Speaking");
      setEqActive(true);
      const icon = MODE_ICONS[s.speakMode] ?? "\u{1F50A}";
      appendTerm(
        `<span class="dt-dim">\u250C\u2500</span> <span class="dt-tool">voice_speak</span>`,
        true,
      );
      appendTerm(
        `<span class="dt-dim">\u2502</span> <span class="dt-str">${icon} ${esc(s.speakMode)} \u2192 "${esc(s.speakText)}"</span>`,
      );
      appendTerm(`<span class="dt-dim">\u2514\u2500</span>`);
      await sleep(2500);
      if (cancelledRef.current) return;

      // Phase 7: Done
      setEqActive(false);
      setVoiceLabel("Idle");
      setTts("done");
      setMode("standby");
      appendTerm(
        `<span class="dt-sys">[voicelayer] Session complete \u00b7 ${s.sttTime} STT \u00b7 non-blocking TTS</span>`,
        true,
      );
      await sleep(2000);
    },
    [appendTerm, typeTranscript],
  );

  useEffect(() => {
    if (!isInView || startedRef.current) return;
    startedRef.current = true;
    cancelledRef.current = false;

    const prefersReduced = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;

    (async () => {
      let i = 0;
      while (!cancelledRef.current) {
        await runCycle(SCENARIOS[i % SCENARIOS.length]);
        if (prefersReduced || cancelledRef.current) break;
        i = (i + 1) % SCENARIOS.length;
        await sleep(1000);
      }
    })();

    return () => {
      cancelledRef.current = true;
      startedRef.current = false;
    };
  }, [isInView, runCycle]);

  return (
    <section id="demo" className="py-20" ref={ref}>
      <div className="mx-auto max-w-[960px] px-6">
        <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 text-center font-medium">
          Live demo
        </div>
        <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] text-center mb-14 leading-[1.15]">
          A voice conversation with your AI
        </h2>
      </div>
      <div className="mx-auto max-w-[1200px] px-6">
        <Terminal maxWidth="820px">
          <Terminal.TitleBar title="voicelayer — session">
            <div className="flex gap-4 font-mono text-[11px] text-text-dim max-md:hidden">
              <span>
                stt:{" "}
                <span
                  className={
                    stt !== "idle" && stt !== "done"
                      ? "text-accent"
                      : "text-text-secondary"
                  }
                >
                  {stt}
                </span>
              </span>
              <span>
                tts:{" "}
                <span
                  className={
                    tts !== "idle" && tts !== "done"
                      ? "text-accent"
                      : "text-text-secondary"
                  }
                >
                  {tts}
                </span>
              </span>
              <span>
                lang:{" "}
                <span
                  className={
                    lang !== "\u2014" ? "text-accent" : "text-text-secondary"
                  }
                >
                  {lang}
                </span>
              </span>
            </div>
          </Terminal.TitleBar>

          <div className="flex min-h-[320px] max-md:flex-col">
            {/* Voice pane */}
            <div className="w-[44%] max-md:w-full border-r max-md:border-r-0 max-md:border-b border-white/[0.05] flex flex-col items-center justify-center p-8 max-md:p-6 gap-5">
              <div className="font-mono text-[11px] text-text-dim uppercase tracking-[0.1em]">
                {voiceLabel}
              </div>
              <Equalizer active={eqActive} />
              <div
                ref={transcriptRef}
                className="font-sans text-sm text-text-secondary text-center leading-[1.6] max-w-[240px] min-h-[44px] font-light"
              />
              <div className="font-mono text-[10px] text-text-dim text-center">
                {meta}
              </div>
            </div>
            {/* Terminal pane */}
            <div
              ref={termRef}
              className="flex-1 p-4 px-5 font-mono text-xs leading-[1.8] overflow-hidden max-md:min-h-[260px] max-md:text-[11px] max-md:p-3"
            />
          </div>

          <Terminal.StatusBar>
            <Terminal.StatusItem label="VoiceBar" value="connected" />
            <Terminal.StatusSep />
            <Terminal.StatusItem
              label="mode"
              value={mode}
              active={mode !== "standby"}
            />
            <Terminal.StatusSep />
            <Terminal.StatusItem label="buffer" value="20 slots" />
            <Terminal.StatusSep />
            <Terminal.StatusItem label="vad" value="silero" />
          </Terminal.StatusBar>
        </Terminal>
      </div>
    </section>
  );
}
