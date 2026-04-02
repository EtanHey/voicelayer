"use client";

import { motion } from "framer-motion";

const FEATURES = [
  {
    title: "F6 push-to-talk",
    desc: "Hold F6 to record, release to transcribe. Global hotkey via Karabiner.",
  },
  {
    title: "Live teleprompter",
    desc: "Words appear as TTS speaks. Auto-scroll, word-level highlighting.",
  },
  {
    title: "Floating pill UI",
    desc: "Waveform visualization during recording. Collapses to a dot when idle. Draggable anywhere.",
  },
];

export function VoiceBar() {
  return (
    <section className="py-16 pb-20">
      <div className="mx-auto max-w-[960px] px-6">
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6 }}
          className="rounded-2xl border border-border bg-bg-elevated p-8 md:p-10"
        >
          <div className="flex items-center gap-2.5 mb-2">
            <span className="px-2 py-0.5 rounded-full border border-accent/20 bg-accent-subtle text-[10px] font-mono text-accent uppercase tracking-[0.08em]">
              Companion App
            </span>
          </div>
          <h2 className="font-display text-[clamp(24px,3vw,32px)] font-semibold tracking-[-0.02em] mb-2 leading-[1.2]">
            Meet VoiceBar
          </h2>
          <p className="text-sm text-text-secondary font-light leading-[1.6] mb-8 max-w-[520px]">
            A native SwiftUI macOS menu bar app that gives VoiceLayer a
            persistent visual presence. Always on, always ready.
          </p>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-5 mb-8">
            {FEATURES.map((f) => (
              <div key={f.title}>
                <h3 className="font-sans text-sm font-medium mb-1.5">
                  {f.title}
                </h3>
                <p className="text-xs text-text-secondary font-light leading-[1.6]">
                  {f.desc}
                </p>
              </div>
            ))}
          </div>

          <p className="text-xs text-text-dim font-light">
            Requires VoiceLayer MCP server. Install with{" "}
            <code className="font-mono text-accent text-[11px]">
              voicelayer bar
            </code>
          </p>
        </motion.div>
      </div>
    </section>
  );
}
