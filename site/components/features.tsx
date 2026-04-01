"use client";

import { motion } from "framer-motion";

const CARDS = [
  {
    icon: (
      <svg
        width="20"
        height="20"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
      >
        <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
        <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
        <line x1="12" y1="19" x2="12" y2="22" />
      </svg>
    ),
    title: "On-device STT",
    description: (
      <>
        <code className="font-mono text-xs text-accent">whisper.cpp</code>{" "}
        large-v3-turbo runs entirely on your Mac. Sub-1.5s transcription, Hebrew
        + English in the same sentence. No cloud, no API key, no latency.
      </>
    ),
  },
  {
    icon: (
      <svg
        width="20"
        height="20"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <rect x="2" y="3" width="20" height="14" rx="2" />
        <line x1="8" y1="21" x2="16" y2="21" />
        <line x1="12" y1="17" x2="12" y2="21" />
      </svg>
    ),
    title: "VoiceBar",
    description:
      "Native SwiftUI menu bar app. F6 push-to-talk via Karabiner, live waveform pill, real-time teleprompter. Collapses to a dot when idle. Draggable anywhere.",
  },
  {
    icon: (
      <svg
        width="20"
        height="20"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <polyline points="4 17 10 11 4 5" />
        <line x1="12" y1="19" x2="20" y2="19" />
      </svg>
    ),
    title: "MCP tools",
    description: (
      <>
        <code className="font-mono text-xs text-accent">voice_speak</code> for
        non-blocking TTS with auto mode detection (announce, brief, consult,
        think). <code className="font-mono text-xs text-accent">voice_ask</code>{" "}
        speaks a question aloud, records your voice response via Silero VAD, and
        returns the transcription.
      </>
    ),
  },
];

export function Features() {
  return (
    <section id="features" className="py-15 pb-20">
      <div className="mx-auto max-w-[960px] px-6">
        <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 text-center font-medium">
          Capabilities
        </div>
        <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] text-center mb-14 leading-[1.15]">
          Built for devs who think faster than they type
        </h2>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-5 max-w-[820px] mx-auto">
          {CARDS.map((card, i) => (
            <motion.div
              key={card.title}
              initial={{ opacity: 0, y: 12 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: i * 0.1 }}
              className="p-7 rounded-[14px] border border-border bg-bg-card hover:border-border-hover hover:-translate-y-0.5 transition-all"
            >
              <div className="w-10 h-10 rounded-[10px] bg-accent-subtle border border-accent/[0.12] flex items-center justify-center mb-4 text-accent">
                {card.icon}
              </div>
              <h3 className="font-sans text-base font-semibold tracking-tight mb-2.5">
                {card.title}
              </h3>
              <p className="text-sm text-text-secondary leading-[1.6] font-light">
                {card.description}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
