"use client";

import { CopyBlock } from "./shared/copy-block";

const EQ_BARS = 25;
const BAR_HEIGHTS = [
  25, 45, 70, 55, 90, 60, 40, 75, 50, 85, 35, 65, 95, 55, 80, 45, 70, 30, 50,
  50, 50, 50, 50, 50, 50,
];

export function Hero() {
  return (
    <section className="pt-40 pb-12 text-center relative overflow-hidden">
      {/* Background glow */}
      <div
        className="absolute top-[45%] left-1/2 -translate-x-1/2 -translate-y-1/2 w-[700px] h-[500px] pointer-events-none"
        style={{
          background:
            "radial-gradient(ellipse, rgba(56, 189, 248, 0.04), transparent 70%)",
        }}
      />

      {/* Equalizer bars background */}
      <div
        className="absolute bottom-[-20px] left-0 right-0 flex items-end justify-center gap-1 h-[260px] opacity-[0.035] pointer-events-none px-[5%]"
        aria-hidden="true"
      >
        {Array.from({ length: EQ_BARS }).map((_, i) => (
          <div
            key={i}
            className="flex-1 max-w-[10px] bg-accent rounded-t-[5px]"
            style={{
              height: `${BAR_HEIGHTS[i % BAR_HEIGHTS.length]}%`,
              transformOrigin: "bottom",
              animation: `eq-pulse ${2 + (i % 3) * 0.5}s ease-in-out infinite`,
              animationDelay: `${(i * 0.15) % 1.5}s`,
            }}
          />
        ))}
      </div>

      <div className="mx-auto max-w-[960px] px-6 relative">
        <h1 className="font-display text-[clamp(40px,6vw,68px)] font-bold tracking-[-0.035em] leading-[1.08] mb-6 max-w-[720px] mx-auto hero-fade">
          Talk to your
          <br />
          <em className="italic text-accent">agents.</em>
        </h1>

        <p className="text-[17px] text-text-secondary max-w-[520px] mx-auto mb-4 leading-[1.65] font-light hero-fade hero-fade-d1">
          You type 40 words per minute. You speak 150. VoiceLayer adds voice to
          Claude Code, Cursor, and every MCP client. Press F6. Speak. Ship.
        </p>

        <p className="text-[13px] text-text-dim tracking-[0.06em] uppercase mb-10 hero-fade hero-fade-d1">
          free &middot; open source &middot; local-first &middot; no cloud
        </p>

        <div className="flex items-center justify-center gap-3 mb-14 hero-fade hero-fade-d2 flex-wrap">
          <a
            href="#setup"
            className="inline-flex items-center gap-2 px-6 py-3 rounded-full text-sm font-medium bg-text text-bg hover:shadow-[0_0_24px_rgba(250,250,249,0.15)] transition-all hover:scale-[1.03] active:scale-[0.98]"
          >
            Get started
          </a>
          <CopyBlock text="bun add -g voicelayer-mcp" />
          <a
            href="https://github.com/EtanHey/voicelayer"
            target="_blank"
            rel="noopener"
            className="inline-flex items-center gap-2 px-6 py-3 rounded-full text-sm font-medium text-text-secondary border border-border hover:text-text hover:border-border-hover transition-all hover:scale-[1.03] active:scale-[0.98]"
          >
            <GithubIcon /> View source
          </a>
        </div>

        {/* VoiceBar Mockup */}
        <div className="max-w-[640px] mx-auto relative hero-fade hero-fade-d3">
          <VoiceBarMockup />
        </div>
      </div>
    </section>
  );
}

function VoiceBarMockup() {
  return (
    <div className="bg-[#0c0c0e] border border-white/[0.06] rounded-[20px] p-8 pb-11 relative overflow-hidden">
      {/* Fade at bottom */}
      <div className="absolute bottom-0 left-0 right-0 h-10 bg-gradient-to-b from-transparent to-bg pointer-events-none" />

      {/* Sound rings */}
      <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none">
        {[0, 1.3, 2.6].map((delay) => (
          <div
            key={delay}
            className="absolute top-1/2 left-1/2 w-[200px] h-[200px] border border-accent/[0.08] rounded-full"
            style={{ animation: `ring-expand 4s ease-out infinite ${delay}s` }}
          />
        ))}
      </div>

      {/* Pill */}
      <div className="flex items-center gap-2.5 bg-accent/[0.08] border border-accent/20 rounded-full px-[18px] py-2 mx-auto w-fit relative">
        <div
          className="absolute -inset-3 rounded-full pointer-events-none"
          style={{
            background:
              "radial-gradient(ellipse, rgba(56, 189, 248, 0.06), transparent 70%)",
          }}
        />
        <div
          className="w-2 h-2 rounded-full bg-accent"
          style={{ animation: "mic-pulse 2s ease-in-out infinite" }}
        />
        <div className="flex items-center gap-[3px] h-5">
          {[6, 12, 18, 14, 20, 16, 10, 8, 14].map((h, i) => (
            <div
              key={i}
              className="w-[3px] bg-accent rounded-sm origin-center"
              style={{
                height: `${h}px`,
                animation: `wave 1.4s ease-in-out infinite ${i * 0.1}s`,
              }}
            />
          ))}
        </div>
        <span className="font-mono text-xs text-accent font-medium">
          Recording
        </span>
      </div>

      {/* Transcript */}
      <div className="mt-7 text-center">
        <div className="font-mono text-[11px] text-text-dim uppercase tracking-[0.1em] mb-2.5">
          Transcribed &middot; whisper.cpp &middot; 1.2s
        </div>
        <p className="font-sans text-[15px] text-text-secondary leading-[1.65] font-light max-w-[440px] mx-auto">
          Split the JWT validation into its own middleware function. Add refresh
          token rotation and keep the cookie fallback for the admin dashboard.
          <span
            className="inline-block w-0.5 h-[1em] bg-accent ml-0.5 align-text-bottom"
            style={{ animation: "blink 1s step-end infinite" }}
          />
        </p>
      </div>
    </div>
  );
}

function GithubIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}
