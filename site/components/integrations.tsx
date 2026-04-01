"use client";

import Image from "next/image";
import { motion } from "framer-motion";
import { CopyBlock } from "./shared/copy-block";

const CLIENTS = [
  { name: "Claude Code", logo: "/logos/claude.svg" },
  { name: "Cursor", logo: "/logos/cursor.svg" },
  { name: "Zed", logo: "/logos/zed.svg" },
  { name: "VS Code", logo: "/logos/vscode.svg" },
  { name: "Codex", logo: "/logos/openai.svg" },
  { name: "Kiro", logo: "/logos/kiro.svg" },
  { name: "Gemini CLI", logo: "/logos/gemini.svg" },
];

const SETUP_STEPS = [
  { num: "01", text: "Install from npm", cmd: "bun add -g voicelayer-mcp" },
  { num: "02", text: "Launch VoiceBar", cmd: "voicelayer bar" },
  { num: "03", text: "Press F6 and start talking", cmd: "Import F6 hotkey" },
];

export function Integrations() {
  return (
    <section id="setup" className="py-20 pb-24 text-center">
      <div className="mx-auto max-w-[960px] px-6">
        <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 font-medium">
          Works with
        </div>
        <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] mb-14 leading-[1.15]">
          Any MCP client
        </h2>

        <motion.div
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          className="flex justify-center gap-10 flex-wrap mb-16 max-md:gap-6"
        >
          {CLIENTS.map((c) => (
            <div
              key={c.name}
              className="flex flex-col items-center gap-2.5 hover:-translate-y-[3px] transition-transform"
            >
              <div className="w-[52px] h-[52px] rounded-xl bg-bg-card border border-border flex items-center justify-center p-[11px] hover:border-border-hover transition-[border-color]">
                <Image
                  src={c.logo}
                  alt={c.name}
                  width={30}
                  height={30}
                  className="w-full h-full object-contain"
                />
              </div>
              <span className="text-xs text-text-dim">{c.name}</span>
            </div>
          ))}
        </motion.div>

        <div className="text-[11px] uppercase tracking-[0.12em] text-accent mb-3 font-medium mt-4">
          Getting started
        </div>
        <h2 className="font-display text-[clamp(26px,3.5vw,36px)] font-semibold tracking-[-0.025em] mb-14 leading-[1.15]">
          Three steps
        </h2>

        <motion.div
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          className="grid grid-cols-1 md:grid-cols-3 gap-4 max-w-[780px] mx-auto"
        >
          {SETUP_STEPS.map((s) => (
            <div key={s.num} className="text-left flex flex-col">
              <div className="font-mono text-[13px] font-medium text-accent mb-2.5">
                {s.num}
              </div>
              <p className="text-sm text-text-secondary leading-[1.6] font-light mb-2.5">
                {s.text}
              </p>
              <div className="mt-auto">
                <CopyBlock text={s.cmd} fullWidth />
              </div>
            </div>
          ))}
        </motion.div>
      </div>
    </section>
  );
}
