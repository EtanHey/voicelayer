"use client";

import { createContext, useContext, type ReactNode } from "react";

/* ─── Context ─── */

interface TerminalContextValue {
  brandColor: string;
}

const TerminalContext = createContext<TerminalContextValue>({
  brandColor: "var(--color-accent)",
});

function useTerminalContext() {
  return useContext(TerminalContext);
}

/* ─── Root ─── */

interface TerminalRootProps {
  children: ReactNode;
  brandColor?: string;
  className?: string;
  maxWidth?: string;
}

function Root({
  children,
  brandColor = "var(--color-accent)",
  className = "",
  maxWidth = "820px",
}: TerminalRootProps) {
  return (
    <TerminalContext.Provider value={{ brandColor }}>
      <div
        className={`bg-[#0c0c0e] border border-white/[0.06] rounded-2xl overflow-hidden relative ${className}`}
        style={{ maxWidth, margin: "0 auto" }}
      >
        {children}
      </div>
    </TerminalContext.Provider>
  );
}

/* ─── Title Bar ─── */

interface TitleBarProps {
  title: string;
  children?: ReactNode;
}

function TitleBar({ title, children }: TitleBarProps) {
  return (
    <div className="flex items-center gap-[7px] px-[18px] py-3 bg-white/[0.03] border-b border-white/[0.05]">
      <div className="w-[11px] h-[11px] rounded-full bg-[#ff5f57]" />
      <div className="w-[11px] h-[11px] rounded-full bg-[#febc2e]" />
      <div className="w-[11px] h-[11px] rounded-full bg-[#28c840]" />
      <span className="text-xs text-text-dim ml-[10px] font-mono">{title}</span>
      {children && <div className="ml-auto">{children}</div>}
    </div>
  );
}

/* ─── Body ─── */

interface BodyProps {
  children: ReactNode;
  className?: string;
}

function Body({ children, className = "" }: BodyProps) {
  return (
    <div className={`p-5 font-mono text-[13px] leading-[1.85] ${className}`}>
      {children}
    </div>
  );
}

/* ─── Status Bar ─── */

interface StatusBarProps {
  children: ReactNode;
}

function StatusBar({ children }: StatusBarProps) {
  const { brandColor } = useTerminalContext();
  return (
    <div
      className="flex items-center gap-4 px-[18px] py-2 bg-white/[0.02] border-t border-white/[0.05] font-mono text-[10px] text-text-dim"
      style={{
        borderTopColor: `color-mix(in srgb, ${brandColor} 10%, transparent)`,
      }}
    >
      {children}
    </div>
  );
}

function StatusSep() {
  return <span className="text-white/[0.08]">|</span>;
}

function StatusItem({
  label,
  value,
  active,
}: {
  label: string;
  value: string;
  active?: boolean;
}) {
  return (
    <span>
      {label}:{" "}
      <span className={active ? "text-accent" : "text-text-secondary"}>
        {value}
      </span>
    </span>
  );
}

/* ─── Tab Bar ─── */

interface TabBarProps {
  tabs: string[];
  activeTab: number;
  onTabChange?: (index: number) => void;
}

function TabBar({ tabs, activeTab, onTabChange }: TabBarProps) {
  return (
    <div className="flex bg-white/[0.02] border-b border-white/[0.04]">
      {tabs.map((tab, i) => (
        <button
          key={tab}
          onClick={() => onTabChange?.(i)}
          className={`px-3.5 py-[5px] font-mono text-[10px] border-b-2 transition-all cursor-pointer select-none ${
            i === activeTab
              ? "text-accent border-accent bg-accent/[0.04]"
              : "text-text-dim border-transparent hover:text-text-secondary hover:bg-white/[0.02]"
          }`}
        >
          {tab}
        </button>
      ))}
    </div>
  );
}

/* ─── Compound Export ─── */

export const Terminal = Object.assign(Root, {
  TitleBar,
  Body,
  StatusBar,
  StatusSep,
  StatusItem,
  TabBar,
});
