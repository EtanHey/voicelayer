"use client";

import {
  AnimatePresence,
  motion,
  useReducedMotion,
  type Transition,
} from "framer-motion";
import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type FocusEvent,
  type ReactNode,
} from "react";

import {
  HYBRID_GEOMETRY,
  HYBRID_MATERIAL,
  HYBRID_MOTION,
  getHybridNotchGeometry,
  type HybridNotchState,
} from "./contract";
import styles from "./unified-glass.module.css";

// EDIT GEOMETRY HERE: every silhouette number used by the mock is collected in
// this object (defined in contract.ts so the same values are testable).
export const EDITABLE_NOTCH_GEOMETRY = HYBRID_GEOMETRY;

const WAVEFORM = [8, 16, 11, 22, 14, 25, 9, 18, 12, 23, 15, 20, 10, 17];
const GLASS_MATERIAL_CLASS = "bg-white/[0.075] backdrop-blur-[28px]";

type MotionPhase = "settled" | "opening" | "closing";
type LauncherAction = "history" | "dictionary" | null;

function Glyph({ name }: { name: "history" | "dictionary" | "mic" | "pause" | "play" | "stop" | "close" | "back" }) {
  const common = "h-[14px] w-[14px] fill-none stroke-current stroke-[1.65] [stroke-linecap:round] [stroke-linejoin:round]";

  if (name === "history") {
    return (
      <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
        <path d="M4.2 6.1A6.5 6.5 0 1 1 3.6 12" />
        <path d="M4.2 2.8v3.4H.9" />
        <path d="M10 6.4v4l2.7 1.6" />
      </svg>
    );
  }
  if (name === "dictionary") {
    return (
      <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
        <path d="M3.3 4.3c2.7-.7 4.9-.2 6.7 1.2v10.2c-1.8-1.4-4-1.9-6.7-1.2Z" />
        <path d="M16.7 4.3c-2.7-.7-4.9-.2-6.7 1.2v10.2c1.8-1.4 4-1.9 6.7-1.2Z" />
      </svg>
    );
  }
  if (name === "mic") {
    return (
      <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
        <rect height="9" rx="3.2" width="6" x="7" y="2.5" />
        <path d="M4.8 9.3a5.2 5.2 0 0 0 10.4 0M10 14.5v3M7.4 17.5h5.2" />
      </svg>
    );
  }
  if (name === "pause") {
    return (
      <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
        <path d="M7 5.2v9.6M13 5.2v9.6" />
      </svg>
    );
  }
  if (name === "play") {
    return (
      <svg aria-hidden="true" className={`${common} fill-current stroke-none`} viewBox="0 0 20 20">
        <path d="m7 4.8 8 5.2-8 5.2Z" />
      </svg>
    );
  }
  if (name === "stop") {
    return (
      <svg aria-hidden="true" className={`${common} stroke-none`} viewBox="0 0 20 20">
        <rect fill="#fff" height="8" rx="1.8" width="8" x="6" y="6" />
      </svg>
    );
  }
  if (name === "back") {
    return (
      <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
        <path d="M5.1 7.2A5.8 5.8 0 1 1 4.7 12" />
        <path d="M5.1 3.8v3.4H1.8" />
      </svg>
    );
  }
  return (
    <svg aria-hidden="true" className={common} viewBox="0 0 20 20">
      <path d="m5.7 5.7 8.6 8.6m0-8.6-8.6 8.6" />
    </svg>
  );
}

function IconButton({
  active = false,
  bare = false,
  className = "",
  label,
  name,
  onClick,
}: {
  active?: boolean;
  bare?: boolean;
  className?: string;
  label: string;
  name: Parameters<typeof Glyph>[0]["name"];
  onClick?: () => void;
}) {
  return (
    <button
      aria-label={label}
      className={`grid h-7 w-7 shrink-0 place-items-center rounded-[9px] border transition-all duration-200 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#a9c8ff] ${
        bare
          ? "border-transparent bg-transparent text-white/72 hover:bg-white/[0.08] hover:text-white"
          : active
          ? "border-white/20 bg-white/18 text-white shadow-[inset_0_1px_0_rgba(255,255,255,.14),0_4px_14px_rgba(0,0,0,.2)]"
          : "border-white/[0.08] bg-white/[0.07] text-white/70 hover:-translate-y-px hover:border-white/15 hover:bg-white/[0.12] hover:text-white"
      } ${className}`}
      onClick={onClick}
      type="button"
    >
      <Glyph name={name} />
    </button>
  );
}

function GlassWing({
  children,
  integratedWithBody,
  reducedMotion,
  side,
  width,
}: {
  children: ReactNode;
  integratedWithBody: boolean;
  reducedMotion: boolean;
  side: "leading" | "trailing";
  width: number;
}) {
  const isLeading = side === "leading";
  const compactOutline = !integratedWithBody && HYBRID_MATERIAL.compactWingBorders
    ? isLeading
      ? "rounded-bl-[11px] border-y border-l border-white/[0.16]"
      : "rounded-br-[11px] border-y border-r border-white/[0.16]"
    : "";
  const seamFadeClass = isLeading
    ? styles.blackToGlassFadeLeft
    : styles.blackToGlassFadeRight;

  return (
    <motion.div
      animate={{ opacity: 1, scaleX: 1 }}
      className={`absolute top-0 z-10 h-8 overflow-hidden ${
        isLeading ? "right-full" : "left-full"
      } ${compactOutline}`}
      data-glass-wing={side}
      exit={{ opacity: 0, scaleX: 0.08 }}
      initial={{ opacity: 0, scaleX: reducedMotion ? 1 : 0.25 }}
      style={{
        transformOrigin: isLeading ? "right center" : "left center",
        width,
      }}
      transition={{ duration: reducedMotion ? 0.05 : 0.2 }}
    >
      {!integratedWithBody ? (
        <div
          aria-hidden="true"
          className={`absolute inset-0 z-0 ${GLASS_MATERIAL_CLASS} ${styles.continuousGlass}`}
          data-glass-wing-material="standalone"
        />
      ) : null}
      <div
        aria-hidden="true"
        className={`absolute top-0 z-20 h-8 w-[var(--blend-width)] ${
          isLeading ? "right-0" : "left-0"
        } ${seamFadeClass}`}
      />
      <div className="relative z-10 h-full w-full">{children}</div>
    </motion.div>
  );
}

function teleprompterGlassClipPath(
  width: number,
  height: number,
  bodyLeftWidth: number,
  leftWingWidth: number,
  rightWingWidth: number,
) {
  const shoulderRadius = 12;
  const bottomRadius = 18;
  const topLeft = bodyLeftWidth - leftWingWidth;
  const topRight =
    bodyLeftWidth + HYBRID_GEOMETRY.core.width + rightWingWidth;

  return `path("M ${topLeft} 0 H ${topRight} V ${HYBRID_GEOMETRY.core.height - shoulderRadius} Q ${topRight} ${HYBRID_GEOMETRY.core.height} ${topRight + shoulderRadius} ${HYBRID_GEOMETRY.core.height} Q ${width} ${HYBRID_GEOMETRY.core.height} ${width} ${HYBRID_GEOMETRY.core.height + shoulderRadius} V ${height - bottomRadius} Q ${width} ${height} ${width - bottomRadius} ${height} H ${bottomRadius} Q 0 ${height} 0 ${height - bottomRadius} V ${HYBRID_GEOMETRY.core.height + shoulderRadius} Q 0 ${HYBRID_GEOMETRY.core.height} ${shoulderRadius} ${HYBRID_GEOMETRY.core.height} H ${topLeft - shoulderRadius} Q ${topLeft} ${HYBRID_GEOMETRY.core.height} ${topLeft} ${HYBRID_GEOMETRY.core.height - shoulderRadius} V 0 Z")`;
}

export function HybridNotchPrototype() {
  const reducedMotion = useReducedMotion();
  const [state, setState] = useState<HybridNotchState>("teleprompter");
  const [hovering, setHovering] = useState(false);
  const [phase, setPhase] = useState<MotionPhase>("settled");
  const [contentVisible, setContentVisible] = useState(true);
  const [paused, setPaused] = useState(false);
  const [launcherAction, setLauncherAction] = useState<LauncherAction>(null);
  const timers = useRef<Array<ReturnType<typeof setTimeout>>>([]);
  const stateRef = useRef<HybridNotchState>(state);
  const effectiveState: HybridNotchState =
    state === "idle" && hovering ? "hover" : state;
  const geometry = getHybridNotchGeometry(effectiveState);
  const glassClipPath = geometry.lowerSurfaceHeight > 0
    ? teleprompterGlassClipPath(
        geometry.width,
        geometry.height,
        geometry.bodyLeftWidth,
        geometry.leftWingWidth,
        geometry.rightWingWidth,
      )
    : "none";
  const glassOutlineClass = geometry.lowerSurfaceHeight > 0
    ? HYBRID_MATERIAL.teleprompterBodyOutline
      ? "border-x border-b border-white/[0.10]"
      : ""
    : "";
  const fadeSafeInnerPadding =
    HYBRID_MATERIAL.blackToGlassBlendPx +
    HYBRID_MATERIAL.fadeToContentGapPx;

  const clearTimers = () => {
    timers.current.forEach((timer) => clearTimeout(timer));
    timers.current = [];
  };

  const applyState = (nextState: HybridNotchState) => {
    stateRef.current = nextState;
    setState(nextState);
  };

  const later = (delay: number, callback: () => void) => {
    const timer = setTimeout(callback, reducedMotion ? Math.min(delay, 40) : delay);
    timers.current.push(timer);
  };

  useEffect(() => clearTimers, []);

  const closeToIdle = () => {
    clearTimers();
    setHovering(false);
    setLauncherAction(null);
    setPaused(false);
    setPhase("closing");
    setContentVisible(false);

    if (stateRef.current === "teleprompter") {
      later(120, () => applyState("recording"));
      later(420, () => applyState("idle"));
      later(720, () => {
        setContentVisible(true);
        setPhase("settled");
      });
      return;
    }

    later(120, () => applyState("idle"));
    later(440, () => {
      setContentVisible(true);
      setPhase("settled");
    });
  };

  const selectState = (nextState: HybridNotchState) => {
    if (nextState === "idle") {
      closeToIdle();
      return;
    }

    clearTimers();
    setHovering(false);
    setLauncherAction(null);
    setPaused(false);
    setPhase("opening");
    setContentVisible(nextState !== "teleprompter");

    if (nextState === "teleprompter" && stateRef.current === "idle") {
      applyState("recording");
      later(50, () => applyState("teleprompter"));
      later(170, () => setContentVisible(true));
    } else {
      applyState(nextState);
      later(nextState === "teleprompter" ? 120 : 40, () =>
        setContentVisible(true),
      );
    }

    later(620, () => setPhase("settled"));
  };

  const replayMorph = () => {
    clearTimers();
    setHovering(false);
    setLauncherAction(null);
    setPaused(false);
    setContentVisible(false);
    setPhase("closing");
    applyState("idle");
    later(420, () => {
      setPhase("opening");
      applyState("recording");
      setContentVisible(true);
    });
    later(940, () => {
      setContentVisible(false);
      applyState("teleprompter");
    });
    later(1_070, () => setContentVisible(true));
    later(1_640, () => setPhase("settled"));
    later(2_450, closeToIdle);
  };

  const handleBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
      setHovering(false);
    }
  };

  const shellTransition: Transition = reducedMotion
    ? { duration: 0.12, ease: "easeOut" }
    : HYBRID_MOTION.spring;
  const shellStyle = {
    "--core-width": `${HYBRID_GEOMETRY.core.width}px`,
    "--core-height": `${HYBRID_GEOMETRY.core.height}px`,
    "--blend-width": `${HYBRID_MATERIAL.blackToGlassBlendPx}px`,
    "--left-wing-width": `${geometry.leftWingWidth}px`,
    "--right-wing-width": `${geometry.rightWingWidth}px`,
    "--lower-height": `${geometry.lowerSurfaceHeight}px`,
  } as CSSProperties;

  return (
    <section className="text-[#f7f8fb]" aria-label="Unified liquid glass notch prototype">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.16em] text-white/40">
            Center candidate · editable geometry
          </p>
          <h2 className="m-0 text-[21px] font-semibold tracking-[-0.035em] text-white">
            Unified liquid glass
          </h2>
          <p className="mt-1.5 text-[12px] text-white/40">
            Black hardware core · glass fades outward · one frameless surface
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div className="flex rounded-[11px] border border-white/[0.08] bg-black/25 p-1">
            {(["idle", "recording", "teleprompter"] as const).map((option) => (
              <button
                className={`rounded-[8px] px-3 py-2 text-[11px] font-medium capitalize transition-colors ${
                  state === option
                    ? "bg-white/[0.12] text-white shadow-[inset_0_1px_0_rgba(255,255,255,.08)]"
                    : "text-white/45 hover:text-white/75"
                }`}
                key={option}
                onClick={() => selectState(option)}
                type="button"
              >
                {option}
              </button>
            ))}
          </div>
          <button
            className="rounded-[11px] border border-white/10 bg-white/[0.07] px-3.5 py-2 text-[11px] font-medium text-white/70 transition-all hover:-translate-y-px hover:bg-white/[0.11] hover:text-white"
            onClick={replayMorph}
            type="button"
          >
            Replay morph
          </button>
        </div>
      </div>

      <div className={`relative h-[calc(100vh-126px)] min-h-[560px] overflow-hidden rounded-[22px] border border-white/[0.09] bg-[radial-gradient(circle_at_74%_28%,rgba(146,86,183,.50),transparent_29%),radial-gradient(circle_at_16%_76%,rgba(38,91,134,.58),transparent_34%),linear-gradient(145deg,#192332,#492e50_58%,#171c27)] shadow-[0_34px_100px_rgba(0,0,0,.36),inset_0_1px_0_rgba(255,255,255,.08)] ${styles.auditStage}`}>
        <div className="absolute inset-x-0 top-0 flex h-8 items-center justify-between px-4 text-[10px] font-medium text-white/70 [text-shadow:0_1px_2px_rgba(0,0,0,.5)]">
          <div className="flex items-center gap-3">
            <span>●</span><span>VoiceLayer</span><span>File</span><span>Edit</span>
          </div>
          <div className="flex items-center gap-3"><span>Control Center</span><span>09:41</span></div>
        </div>

        <motion.div
          animate={{ height: geometry.height }}
          className="absolute left-1/2 top-0 z-10 w-[185px] -translate-x-1/2 overflow-visible"
          data-phase={phase}
          data-state={effectiveState}
          initial={false}
          onBlurCapture={handleBlur}
          onFocusCapture={() => state === "idle" && setHovering(true)}
          onMouseEnter={() => state === "idle" && setHovering(true)}
          onMouseLeave={() => state === "idle" && setHovering(false)}
          style={shellStyle}
          transition={shellTransition}
        >
          <motion.div
            animate={{
              borderBottomLeftRadius: geometry.lowerSurfaceHeight > 0 ? 18 : 11,
              borderBottomRightRadius: geometry.lowerSurfaceHeight > 0 ? 18 : 11,
              clipPath: glassClipPath,
              height: geometry.height,
              left: -geometry.bodyLeftWidth,
              opacity: geometry.lowerSurfaceHeight > 0 ? 1 : 0,
              width: geometry.width,
            }}
            className={`absolute top-0 z-0 overflow-hidden ${GLASS_MATERIAL_CLASS} ${glassOutlineClass} ${styles.continuousGlass}`}
            initial={false}
            transition={shellTransition}
          />

          <AnimatePresence initial={false}>
            {geometry.leftWingWidth > 0 ? (
              <GlassWing
                integratedWithBody={geometry.lowerSurfaceHeight > 0}
                reducedMotion={Boolean(reducedMotion)}
                side="leading"
                width={geometry.leftWingWidth}
              >
              {effectiveState === "hover" ? (
                <motion.div
                  animate={{ opacity: 1, x: 0 }}
                  className="relative z-10 flex h-full w-full items-center justify-center"
                  data-launcher-wing="leading"
                  initial={{ opacity: 0, x: 6 }}
                >
                  <IconButton
                    bare
                    className="!text-[#dbe7ff]"
                    label="Start recording"
                    name="mic"
                    onClick={() => selectState("recording")}
                  />
                </motion.div>
              ) : effectiveState === "recording" || effectiveState === "teleprompter" ? (
                <AnimatePresence mode="popLayout">
                  {contentVisible ? (
                    <motion.div
                      animate={{ opacity: 1, x: 0 }}
                      className="relative z-10 flex h-full w-full items-center justify-center gap-1.5 text-[9px] text-white/68"
                      exit={{ opacity: 0, x: 5 }}
                      initial={{ opacity: 0, x: 5 }}
                      key={effectiveState}
                      style={{
                        paddingLeft:
                          effectiveState === "teleprompter"
                            ? HYBRID_MATERIAL.wingOuterPaddingPx
                            : 4,
                        paddingRight:
                          effectiveState === "teleprompter"
                            ? fadeSafeInnerPadding
                            : 4,
                      }}
                    >
                      {effectiveState === "recording" ? <span className="h-1.5 w-1.5 rounded-full bg-[#ff6663] shadow-[0_0_8px_rgba(255,89,85,.7)]" /> : null}
                      <Glyph name={effectiveState === "recording" ? "mic" : "dictionary"} />
                      <span className="font-mono tabular-nums text-white/55">0:08</span>
                    </motion.div>
                  ) : null}
                </AnimatePresence>
              ) : null}
              </GlassWing>
            ) : null}
          </AnimatePresence>

          <AnimatePresence initial={false}>
            {geometry.rightWingWidth > 0 ? (
              <GlassWing
                integratedWithBody={geometry.lowerSurfaceHeight > 0}
                reducedMotion={Boolean(reducedMotion)}
                side="trailing"
                width={geometry.rightWingWidth}
              >
              {effectiveState === "hover" ? (
                <motion.div
                  animate={{ opacity: 1, x: 0 }}
                  className="relative z-10 flex h-full w-full items-center justify-center gap-1"
                  data-launcher-wing="trailing"
                  initial={{ opacity: 0, x: -6 }}
                >
                  <IconButton
                    active={launcherAction === "history"}
                    bare
                    label="Open history"
                    name="history"
                    onClick={() => setLauncherAction("history")}
                  />
                  <IconButton
                    active={launcherAction === "dictionary"}
                    bare
                    label="Open dictionary"
                    name="dictionary"
                    onClick={() => setLauncherAction("dictionary")}
                  />
                </motion.div>
              ) : effectiveState === "recording" || effectiveState === "teleprompter" ? (
                <AnimatePresence mode="popLayout">
                  {contentVisible ? (
                    <motion.div
                      animate={{ opacity: 1, x: 0 }}
                      className="relative z-10 flex h-full w-full items-center gap-0.5"
                      exit={{ opacity: 0, x: -5 }}
                      initial={{ opacity: 0, x: -5 }}
                      key={effectiveState}
                      style={{
                        paddingLeft:
                          effectiveState === "teleprompter"
                            ? fadeSafeInnerPadding
                            : 6,
                        paddingRight:
                          effectiveState === "teleprompter"
                            ? HYBRID_MATERIAL.wingOuterPaddingPx
                            : 4,
                      }}
                    >
                      <div className="flex h-6 w-14 shrink-0 items-center justify-center gap-[2px] overflow-hidden" aria-label="Live waveform">
                        {WAVEFORM.map((height, index) => (
                          <motion.span
                            animate={{ height: paused ? 4 : height }}
                            className="block w-[2px] rounded-full bg-gradient-to-b from-[#c3d6ff] to-[#7596e0] shadow-[0_0_6px_rgba(125,162,237,.22)]"
                            key={index}
                            transition={{ duration: 0.16, delay: phase === "closing" ? index * 0.012 : 0 }}
                          />
                        ))}
                      </div>
                      {effectiveState === "recording" ? (
                        <div className="flex items-center gap-0.5">
                          <IconButton className="!h-6 !w-6 !rounded-[8px]" label={paused ? "Resume recording" : "Pause recording"} name={paused ? "play" : "pause"} onClick={() => setPaused((value) => !value)} />
                          <IconButton className="!h-6 !w-6 !rounded-[8px] !border-[#ff7775]/50 !bg-[#d84e50] !text-white shadow-[0_0_12px_rgba(225,75,78,.24)]" label="Stop recording" name="stop" onClick={closeToIdle} />
                          <IconButton className="!h-6 !w-6 !rounded-[8px]" label="Cancel recording" name="close" onClick={closeToIdle} />
                        </div>
                      ) : null}
                    </motion.div>
                  ) : null}
                </AnimatePresence>
              ) : null}
              </GlassWing>
            ) : null}
          </AnimatePresence>

          <AnimatePresence initial={false}>
            {geometry.lowerSurfaceHeight > 0 ? (
              <motion.div
              animate={{ opacity: 1, scaleY: 1 }}
              className="absolute top-8 z-10 origin-top overflow-hidden"
              exit={{ opacity: 0, scaleY: 0.02 }}
              initial={{ opacity: 0, scaleY: reducedMotion ? 1 : 0.96 }}
              style={{
                height: geometry.lowerSurfaceHeight,
                left: -geometry.bodyLeftWidth,
                width: geometry.width,
              }}
              transition={{ ...shellTransition, delay: effectiveState === "teleprompter" ? HYBRID_MOTION.panelDelaySeconds : 0 }}
            >
              <div className={styles.coreDownFade} />

              {effectiveState === "teleprompter" ? (
                <AnimatePresence>
                  {contentVisible ? (
                    <motion.div
                      animate={{ opacity: 1, y: 0 }}
                      className="relative z-10 flex h-full flex-col px-9 pb-5 pt-7"
                      exit={{ opacity: 0, y: -7, transition: { duration: HYBRID_MOTION.contentExitSeconds } }}
                      initial={{ opacity: 0, y: 8 }}
                      transition={{ delay: reducedMotion ? 0 : 0.08, duration: reducedMotion ? 0.08 : 0.24 }}
                    >
                      <div className="flex flex-1 flex-col items-center justify-center gap-2 text-center [text-shadow:0_1px_7px_rgba(0,0,0,.48)]">
                        <p className="m-0 text-[12px] font-medium text-white/30">The material begins at the hardware—</p>
                        <p className="m-0 text-[15px] font-semibold tracking-[-0.015em] text-white/95">glass opens outward, while the words stay in focus.</p>
                        <p className="m-0 text-[12px] font-medium text-white/28">Nothing is framed inside another panel.</p>
                      </div>

                      <div className="mb-4 flex items-center gap-3 font-mono text-[8px] text-white/36">
                        <span>0:08</span>
                        <div className="relative h-px flex-1 bg-white/18">
                          <motion.span animate={{ width: paused ? "38%" : "56%" }} className="absolute inset-y-0 left-0 bg-[#b7cbff] shadow-[0_0_9px_rgba(167,194,255,.45)]" />
                          <span className="absolute left-[56%] top-1/2 h-1.5 w-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#dce7ff] shadow-[0_0_8px_rgba(190,211,255,.5)]" />
                        </div>
                        <span>0:21</span>
                      </div>

                      <div className="flex items-center justify-center gap-2.5">
                        <IconButton label="Go back five seconds" name="back" />
                        <IconButton active className="!h-8 !w-8 !rounded-full !bg-white/[0.16] !text-white" label={paused ? "Resume teleprompter" : "Pause teleprompter"} name={paused ? "play" : "pause"} onClick={() => setPaused((value) => !value)} />
                        <IconButton label="Close teleprompter" name="close" onClick={closeToIdle} />
                      </div>
                    </motion.div>
                  ) : null}
                </AnimatePresence>
              ) : null}
              </motion.div>
            ) : null}
          </AnimatePresence>

          <div
            aria-label="Physical camera housing"
            className={`absolute left-0 top-0 z-30 h-8 w-[185px] bg-black ${styles.hardwareCore}`}
            tabIndex={state === "idle" ? 0 : -1}
          >
            <span className="absolute left-1/2 top-[10px] h-[5px] w-[5px] -translate-x-1/2 rounded-full border border-white/[0.035] bg-[#08090b] shadow-[inset_0_0_2px_#000]" />
          </div>
        </motion.div>

        <div className="absolute bottom-4 left-4 flex items-center gap-2 text-[9px] font-semibold uppercase tracking-[0.12em] text-white/35">
          <span className={`h-1.5 w-1.5 rounded-full ${phase === "closing" ? "bg-[#ed8c85]" : phase === "opening" ? "bg-[#9db8f5]" : "bg-white/35"}`} />
          <span>{phase}</span>
          <span className="text-white/20">·</span>
          <span>{geometry.width} × {geometry.height}</span>
        </div>
        <div className="absolute bottom-4 right-4 text-[9px] font-semibold uppercase tracking-[0.12em] text-white/30">
          Hover idle core for launcher
        </div>
      </div>
    </section>
  );
}

export default HybridNotchPrototype;
