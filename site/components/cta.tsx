"use client";

import { motion } from "framer-motion";
import { CopyBlock } from "./shared/copy-block";

export function Cta() {
  return (
    <section className="py-16 text-center">
      <div className="mx-auto max-w-[960px] px-6">
        <motion.h2
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          className="font-display text-[clamp(26px,4vw,42px)] font-semibold tracking-[-0.03em] mb-3"
        >
          Stop typing. Start talking.
        </motion.h2>
        <motion.p
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ delay: 0.1 }}
          className="text-text-secondary text-[15px] mb-9 font-light"
        >
          One install. On-device STT. Works with any MCP client.
        </motion.p>
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          transition={{ delay: 0.2 }}
        >
          <CopyBlock text="bun add -g voicelayer-mcp" showDollar />
        </motion.div>
      </div>
    </section>
  );
}
