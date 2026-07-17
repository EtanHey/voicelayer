"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";

import styles from "./adaptive-notch.module.css";
import {
  ADAPTIVE_NOTCH_TOKENS,
  getAdaptiveNotchGeometry,
  type AdaptiveNotchState,
} from "./geometry";

export type AdaptiveAuditBackground = "dark" | "light" | "purple";

interface AdaptiveNotchPrototypeProps {
  auditBackground?: AdaptiveAuditBackground;
  initialState?: AdaptiveNotchState;
  onStateChange?: (state: AdaptiveNotchState) => void;
  showStateControls?: boolean;
  state?: AdaptiveNotchState;
}

type WaveformPhase = "live" | "paused" | "decaying";

const STATES: readonly AdaptiveNotchState[] = [
  "idle",
  "recording",
  "teleprompter",
];

const WAVEFORM_LEVELS = [
  0.22, 0.5, 0.72, 0.38, 0.94, 0.62, 0.32, 0.82, 0.52, 0.26, 0.68,
  0.44, 0.3, 0.58,
] as const;

export function AdaptiveNotchPrototype({
  auditBackground = "purple",
  initialState = "recording",
  onStateChange,
  showStateControls = true,
  state,
}: AdaptiveNotchPrototypeProps) {
  const [internalState, setInternalState] =
    useState<AdaptiveNotchState>(initialState);
  const [waveformPhase, setWaveformPhase] =
    useState<WaveformPhase>("live");
  const stopTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const activeState = state ?? internalState;
  const geometry = getAdaptiveNotchGeometry(activeState);

  useEffect(() => {
    return () => {
      if (stopTimer.current) clearTimeout(stopTimer.current);
    };
  }, []);

  function selectState(nextState: AdaptiveNotchState) {
    if (stopTimer.current) clearTimeout(stopTimer.current);
    setWaveformPhase("live");
    if (state === undefined) setInternalState(nextState);
    onStateChange?.(nextState);
  }

  function stopRecording() {
    setWaveformPhase("decaying");
    stopTimer.current = setTimeout(() => selectState("idle"), 920);
  }

  const shellStyle = {
    "--inverse-join": `${ADAPTIVE_NOTCH_TOKENS.inverseJoin}px`,
    "--waveform-slot": `${ADAPTIVE_NOTCH_TOKENS.waveformSlot}px`,
    height: geometry.shell.height,
    width: geometry.shell.width,
  } as CSSProperties;

  return (
    <section className={styles.prototype} aria-label="Adaptive glass notch prototype">
      <div className={styles.prototypeHeader}>
        <div>
          <p className={styles.eyebrow}>Variant B</p>
          <h2 className={styles.title}>Adaptive glass</h2>
        </div>
        {showStateControls ? (
          <div className={styles.stateControls} aria-label="Notch preview state">
            {STATES.map((previewState) => (
              <button
                className={styles.stateButton}
                data-active={activeState === previewState}
                key={previewState}
                onClick={() => selectState(previewState)}
                type="button"
              >
                {previewState}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      <div
        className={`${styles.stage} ${styles[`stage-${auditBackground}`]}`}
        data-audit-background={auditBackground}
      >
        <div className={styles.menuBar} aria-hidden="true">
          <span>●&nbsp;&nbsp;VoiceLayer&nbsp;&nbsp;File&nbsp;&nbsp;Edit</span>
          <span>Control Center&nbsp;&nbsp;&nbsp;09:41</span>
        </div>

        <div
          className={styles.shell}
          data-clip="exact-shell"
          data-state={activeState}
          style={shellStyle}
        >
          <div
            className={styles.topBand}
            data-expanded={activeState !== "idle"}
          >
            {activeState !== "idle" ? (
              <div
                className={`${styles.wing} ${styles.leftWing}`}
                data-material-region="left-wing"
              >
                {activeState === "recording" ? (
                  <>
                    <span className={styles.liveDot} aria-hidden="true" />
                    <svg
                      aria-hidden="true"
                      className={styles.micIcon}
                      viewBox="0 0 24 24"
                    >
                      <rect height="12" rx="4" width="7" x="8.5" y="3" />
                      <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3M9 21h6" />
                    </svg>
                    <span className={styles.timer}>00:17</span>
                  </>
                ) : (
                  <>
                    <span className={styles.liveDot} aria-hidden="true" />
                    <svg
                      aria-label="Speaking"
                      className={styles.micIcon}
                      role="img"
                      viewBox="0 0 20 20"
                    >
                      <path d="M4.5 8h2.8l3.4-3v10l-3.4-3H4.5Zm9-.5a4 4 0 0 1 0 5m1.8-7a6.7 6.7 0 0 1 0 9" />
                    </svg>
                    <span className={styles.timer}>00:17</span>
                  </>
                )}
              </div>
            ) : null}

            <div className={styles.hardwareCore} data-material="opaque-black">
              <span className={styles.cameraDot} aria-hidden="true" />
            </div>

            {activeState !== "idle" ? (
              <div
                className={`${styles.wing} ${styles.rightWing}`}
                data-material-region="right-wing"
              >
                <div
                  className={styles.waveform}
                  data-phase={waveformPhase}
                  role="img"
                  aria-label={
                    waveformPhase === "paused"
                      ? "Paused waveform"
                      : "Live waveform"
                  }
                >
                  {WAVEFORM_LEVELS.map((level, index) => (
                    <i
                      key={`${level}-${index}`}
                      style={
                        {
                          "--bar-delay": `${index * 42}ms`,
                          "--bar-level": level,
                        } as CSSProperties
                      }
                    />
                  ))}
                </div>

                <button
                  aria-label={
                    waveformPhase === "paused" ? "Resume" : "Pause"
                  }
                  className={styles.iconButton}
                  onClick={() =>
                    setWaveformPhase((phase) =>
                      phase === "paused" ? "live" : "paused",
                    )
                  }
                  type="button"
                >
                  {waveformPhase === "paused" ? "▶" : "Ⅱ"}
                </button>
                <button
                  aria-label="Stop"
                  className={`${styles.iconButton} ${styles.stopButton}`}
                  onClick={stopRecording}
                  type="button"
                >
                  <span aria-hidden="true" />
                </button>
                <button
                  aria-label="Cancel"
                  className={styles.iconButton}
                  onClick={() => selectState("idle")}
                  type="button"
                >
                  ×
                </button>
              </div>
            ) : null}
          </div>

          {activeState === "teleprompter" ? (
            <div
              className={styles.teleprompterPanel}
              data-material-region="lower-panel"
            >
              <div className={styles.teleprompterContent}>
                <p className={styles.previousLine}>
                  The proof should feel attached to the hardware,
                </p>
                <p className={styles.currentLine}>
                  not like another floating utility window.
                </p>
                <p className={styles.nextLine}>
                  Keep the words moving linearly and quietly.
                </p>

                <div className={styles.progress} aria-label="Playback progress">
                  <span>0:08</span>
                  <div className={styles.progressTrack}>
                    <span />
                  </div>
                  <span>0:21</span>
                </div>

                <div className={styles.transport}>
                  <button aria-label="Restart" type="button">
                    ↺
                  </button>
                  <button
                    aria-label="Pause teleprompter"
                    className={styles.primaryTransport}
                    onClick={() =>
                      setWaveformPhase((phase) =>
                        phase === "paused" ? "live" : "paused",
                      )
                    }
                    type="button"
                  >
                    {waveformPhase === "paused" ? "▶" : "Ⅱ"}
                  </button>
                  <button
                    aria-label="Close teleprompter"
                    onClick={() => selectState("idle")}
                    type="button"
                  >
                    ×
                  </button>
                </div>
              </div>
            </div>
          ) : null}
        </div>

        <div className={styles.auditLabel}>
          <span>185 × 32 hardware core</span>
          <span>glass clipped to shell</span>
        </div>
      </div>
    </section>
  );
}

export default AdaptiveNotchPrototype;
