"use client";

import { useState, useCallback } from "react";

interface CopyBlockProps {
  text: string;
  showDollar?: boolean;
  fullWidth?: boolean;
}

export function CopyBlock({
  text,
  showDollar = false,
  fullWidth = false,
}: CopyBlockProps) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [text]);

  return (
    <button
      onClick={handleCopy}
      className={`flex items-center bg-bg-card border border-border rounded-[10px] px-[18px] py-3 font-mono text-sm text-text-secondary cursor-pointer transition-[border-color] duration-200 hover:border-accent ${
        fullWidth ? "w-full" : "max-w-[420px] mx-auto"
      }`}
    >
      <code className="text-text flex-1 text-left">
        {showDollar && <span className="text-text-dim">$ </span>}
        {text}
      </code>
      <span className="w-6 h-6 flex items-center justify-center shrink-0">
        {copied ? (
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="var(--color-accent)"
            strokeWidth="2"
          >
            <path d="M3 8.5l3 3 7-7" />
          </svg>
        ) : (
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            className="text-text-dim hover:text-accent transition-colors"
          >
            <rect x="5" y="5" width="9" height="9" rx="1.5" />
            <path d="M5 11H3.5A1.5 1.5 0 012 9.5v-6A1.5 1.5 0 013.5 2h6A1.5 1.5 0 0111 3.5V5" />
          </svg>
        )}
      </span>
    </button>
  );
}
