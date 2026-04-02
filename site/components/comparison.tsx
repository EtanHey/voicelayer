"use client";

import { motion } from "framer-motion";

const WITHOUT = [
  "Type every instruction at 40 WPM",
  "Hands glued to keyboard during QA",
  "Context-switch to type quick notes",
  "150 WPM brain, 40 WPM fingers",
  "No way to do voice-first workflows",
];

const WITH = [
  "Speak naturally to your AI at 150 WPM",
  "Hands-free code review and QA testing",
  "Voice notes while browsing the app",
  "Local transcription in under 1.5 seconds",
  "5 voice modes: announce, brief, consult, converse, think",
];

export function Comparison() {
  return (
    <section className="py-16 pb-20">
      <div className="mx-auto max-w-[960px] px-6">
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6 }}
        >
          <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 text-center font-medium">
            The bottleneck
          </div>
          <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] text-center mb-4 leading-[1.15]">
            Your fingers are the slowest part
          </h2>
          <p className="text-sm text-text-secondary text-center max-w-[480px] mx-auto mb-12 font-light leading-[1.6]">
            You think at the speed of speech. Your AI should listen.
          </p>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4 max-w-[820px] mx-auto">
            {/* WITHOUT */}
            <div className="rounded-[14px] border border-border bg-bg-card p-7">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-text-dim mb-5">
                Without VoiceLayer
              </div>
              <ul className="space-y-3.5">
                {WITHOUT.map((item) => (
                  <li key={item} className="flex items-start gap-3">
                    <span className="text-red shrink-0 mt-0.5 font-mono text-sm">
                      &times;
                    </span>
                    <span className="text-sm text-text-secondary font-light leading-[1.5]">
                      {item}
                    </span>
                  </li>
                ))}
              </ul>
            </div>

            {/* WITH */}
            <div className="rounded-[14px] border border-accent/20 bg-accent-subtle p-7">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-accent mb-5">
                With VoiceLayer
              </div>
              <ul className="space-y-3.5">
                {WITH.map((item) => (
                  <li key={item} className="flex items-start gap-3">
                    <span className="text-accent shrink-0 mt-0.5 font-mono text-sm">
                      &check;
                    </span>
                    <span className="text-sm text-text font-light leading-[1.5]">
                      {item}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          </div>

          <p className="text-xs text-text-dim text-center mt-8 max-w-[420px] mx-auto font-light leading-[1.7]">
            Prefer typing? VoiceLayer is optional per-session. Enable it when
            you want speed. Disable it in shared offices. Your workflow, your
            choice.
          </p>
        </motion.div>
      </div>
    </section>
  );
}
