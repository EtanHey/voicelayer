"use client";

import { motion } from "framer-motion";

const STEPS = [
  {
    icon: (
      <span className="inline-flex items-center justify-center px-2.5 py-1 bg-gradient-to-b from-[#2a2a30] to-[#1a1a1e] border border-[#3a3a40] rounded-md shadow-[0_2px_0_#111,inset_0_1px_0_rgba(255,255,255,0.05)] font-mono text-xs font-semibold text-accent">
        F6
      </span>
    ),
    label: "Hold F6",
    time: "0ms",
    desc: "Karabiner hotkey triggers VoiceBar recording",
  },
  {
    icon: (
      <svg
        width="24"
        height="24"
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
    label: "Speak",
    time: "~3s",
    desc: "Silero VAD detects speech & silence",
  },
  {
    icon: (
      <svg
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M12 20h9" />
        <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
      </svg>
    ),
    label: "Transcribe",
    time: "~1.1s",
    desc: "whisper.cpp large-v3-turbo, on-device",
  },
  {
    icon: (
      <svg
        width="24"
        height="24"
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
    label: "Paste",
    time: "instant",
    desc: "Auto-pastes into your active field",
  },
];

function Arrow() {
  return (
    <div className="shrink-0 w-10 flex items-center justify-center text-border-hover mb-10 max-md:rotate-90 max-md:mb-0">
      <svg
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
      >
        <path d="M5 12h14m-4-4 4 4-4 4" />
      </svg>
    </div>
  );
}

export function Pipeline() {
  return (
    <section className="py-15 pb-20">
      <div className="mx-auto max-w-[960px] px-6">
        <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 text-center font-medium">
          How it works
        </div>
        <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] text-center mb-14 leading-[1.15]">
          F6 &rarr; text at your cursor in &lt;2 seconds
        </h2>

        <motion.div
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6 }}
          className="flex items-center justify-center max-w-[860px] mx-auto max-md:flex-col max-md:gap-4"
        >
          {STEPS.map((step, i) => (
            <div key={step.label} className="contents">
              <div className="flex flex-col items-center text-center flex-1 group">
                <div className="w-16 h-16 rounded-2xl bg-bg-card border border-border flex items-center justify-center mb-3.5 relative z-[1] transition-all group-hover:border-accent group-hover:-translate-y-0.5 text-accent">
                  {step.icon}
                </div>
                <div className="font-sans text-sm font-medium text-text mb-1">
                  {step.label}
                </div>
                <div className="font-mono text-xs text-accent font-medium">
                  {step.time}
                </div>
                <div className="text-xs text-text-dim font-light max-w-[120px] mt-1 max-md:max-w-[200px]">
                  {step.desc}
                </div>
              </div>
              {i < STEPS.length - 1 && <Arrow />}
            </div>
          ))}
        </motion.div>
      </div>
    </section>
  );
}
