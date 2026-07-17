"use client";

import { useEffect, useState, type CSSProperties } from "react";

import {
  getNeutralNotchGeometry,
  type NeutralNotchState,
} from "./geometry";
import styles from "./neutral-notch.module.css";

const STATE_OPTIONS: ReadonlyArray<{
  value: NeutralNotchState;
  label: string;
}> = [
  { value: "idle", label: "Idle" },
  { value: "recording", label: "Recording" },
  { value: "teleprompter", label: "Teleprompter" },
];

const WAVE_FRAMES = [
  [4, 10, 15, 8, 20, 13, 7, 17, 11, 5, 14, 9, 6, 12],
  [7, 15, 9, 19, 12, 6, 16, 10, 21, 13, 8, 18, 11, 5],
  [12, 7, 18, 11, 5, 15, 22, 9, 13, 17, 6, 12, 19, 8],
  [6, 13, 8, 16, 21, 10, 14, 7, 18, 12, 20, 9, 15, 5],
] as const;

export function NeutralNotchPrototype() {
  const [state, setState] = useState<NeutralNotchState>("recording");
  const [paused, setPaused] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [waveFrame, setWaveFrame] = useState(0);
  const [elapsed, setElapsed] = useState(8);
  const geometry = getNeutralNotchGeometry(state);
  const isLive = state !== "idle";

  useEffect(() => {
    if (!isLive || paused || stopping) return;

    const timer = window.setInterval(() => {
      setWaveFrame((frame) => (frame + 1) % WAVE_FRAMES.length);
    }, 120);

    return () => window.clearInterval(timer);
  }, [isLive, paused, stopping]);

  useEffect(() => {
    if (!isLive || paused || stopping) return;

    const timer = window.setInterval(() => {
      setElapsed((value) => value + 1);
    }, 1_000);

    return () => window.clearInterval(timer);
  }, [isLive, paused, stopping]);

  useEffect(() => {
    if (state === "idle") {
      setPaused(false);
      setStopping(false);
      setElapsed(0);
    }
  }, [state]);

  const chooseState = (nextState: NeutralNotchState) => {
    setStopping(false);
    setPaused(false);
    setElapsed(nextState === "idle" ? 0 : 8);
    setState(nextState);
  };

  const stop = () => {
    if (!isLive || stopping) return;

    setStopping(true);
    setPaused(true);
    window.setTimeout(() => setState("idle"), 920);
  };

  const cancel = () => {
    setStopping(false);
    setState("idle");
  };

  const shellStyle = {
    "--shell-width": `${geometry.width}px`,
    "--shell-height": `${geometry.height}px`,
    "--core-width": `${geometry.cameraGapWidth}px`,
    "--left-wing-width": `${geometry.leftWingWidth}px`,
    "--right-wing-width": `${geometry.rightWingWidth}px`,
    "--panel-height": `${geometry.lowerPanelHeight}px`,
    "--waveform-width": `${geometry.waveformSlotWidth}px`,
    "--inverse-join": `${geometry.inverseJoinRadius}px`,
  } as CSSProperties;
  const minutes = Math.floor(elapsed / 60)
    .toString()
    .padStart(2, "0");
  const seconds = (elapsed % 60).toString().padStart(2, "0");
  const liveLabel =
    state === "teleprompter" ? "Speaking" : paused ? "Paused" : "Live";

  return (
    <section className={styles.prototype} aria-label="Neutral smoke notch mock">
      <div className={styles.prototypeHeader}>
        <div>
          <p className={styles.eyebrow}>Variant A</p>
          <h2 className={styles.title}>Neutral smoke</h2>
        </div>
        <div className={styles.statePicker} aria-label="Preview state">
          {STATE_OPTIONS.map((option) => (
            <button
              className={styles.stateButton}
              data-selected={state === option.value}
              key={option.value}
              onClick={() => chooseState(option.value)}
              type="button"
            >
              {option.label}
            </button>
          ))}
        </div>
      </div>

      <div className={styles.preview}>
        <div className={styles.menuBar} aria-hidden="true">
          <div className={styles.menuItems}>
            <span className={styles.apple}>●</span>
            <span>VoiceLayer</span>
            <span>File</span>
            <span>Edit</span>
          </div>
          <div className={styles.menuItems}>
            <span>Control Center</span>
            <span>09:41</span>
          </div>
        </div>

        <div
          className={styles.shell}
          data-paused={paused}
          data-state={state}
          data-stopping={stopping}
          style={shellStyle}
        >
          <div className={styles.band}>
            <div className={styles.leftWing} aria-hidden={!isLive}>
              <span className={styles.liveDot} />
              {state === "teleprompter" ? (
                <svg
                  aria-label={liveLabel}
                  className={styles.activityIcon}
                  role="img"
                  viewBox="0 0 20 20"
                >
                  <path d="M4.5 8h2.8l3.4-3v10l-3.4-3H4.5Zm9-.5a4 4 0 0 1 0 5m1.8-7a6.7 6.7 0 0 1 0 9" />
                </svg>
              ) : (
                <svg
                  aria-label={liveLabel}
                  className={styles.activityIcon}
                  role="img"
                  viewBox="0 0 20 20"
                >
                  <rect height="8" rx="3" width="5" x="7.5" y="3" />
                  <path d="M5.5 9.5a4.5 4.5 0 0 0 9 0M10 14v3m-2 0h4" />
                </svg>
              )}
              <time className={styles.timer} dateTime={`PT${elapsed}S`}>
                {minutes}:{seconds}
              </time>
            </div>

            <div className={styles.hardwareCore} aria-label="Camera housing">
              <span className={styles.camera} />
            </div>

            <div className={styles.rightWing} aria-hidden={!isLive}>
              <div className={styles.waveform} aria-label="Live input waveform">
                {WAVE_FRAMES[waveFrame].map((height, index) => (
                  <span
                    className={styles.waveBar}
                    key={index}
                    style={{ height: `${stopping ? 3 : height}px` }}
                  />
                ))}
              </div>

              <div className={styles.actions}>
                <button
                  aria-label={paused ? "Resume" : "Pause"}
                  className={styles.iconButton}
                  onClick={() => setPaused((value) => !value)}
                  type="button"
                >
                  {paused ? (
                    <svg aria-hidden="true" viewBox="0 0 20 20">
                      <path d="m7 5 7 5-7 5Z" />
                    </svg>
                  ) : (
                    <svg aria-hidden="true" viewBox="0 0 20 20">
                      <path d="M6.5 5.5v9M13.5 5.5v9" />
                    </svg>
                  )}
                </button>
                <button
                  aria-label="Stop"
                  className={`${styles.iconButton} ${styles.stopButton}`}
                  onClick={stop}
                  type="button"
                >
                  <svg aria-hidden="true" viewBox="0 0 20 20">
                    <rect height="7" rx="1.5" width="7" x="6.5" y="6.5" />
                  </svg>
                </button>
                <button
                  aria-label="Cancel"
                  className={styles.iconButton}
                  onClick={cancel}
                  type="button"
                >
                  <svg aria-hidden="true" viewBox="0 0 20 20">
                    <path d="m6.5 6.5 7 7m0-7-7 7" />
                  </svg>
                </button>
              </div>
            </div>
          </div>

          <div className={styles.teleprompter} aria-hidden={state !== "teleprompter"}>
            <div className={styles.transcript}>
              <p className={styles.previousLine}>
                The proof should feel attached to the hardware,
              </p>
              <p className={styles.currentLine}>
                not like another floating utility window.
              </p>
              <p className={styles.nextLine}>
                Keep the words moving linearly and quietly.
              </p>
            </div>

            <div className={styles.progressRow}>
              <span>0:08</span>
              <div className={styles.progressTrack} aria-label="Playback progress">
                <span className={styles.progressFill} />
                <span className={styles.progressThumb} />
              </div>
              <span>0:21</span>
            </div>

            <div className={styles.transport}>
              <button aria-label="Restart" className={styles.transportButton} type="button">
                <svg aria-hidden="true" viewBox="0 0 20 20">
                  <path d="M5.2 7.2A5.7 5.7 0 1 1 4.7 12M5.2 3.8v3.4H1.8" />
                </svg>
              </button>
              <button
                aria-label={paused ? "Resume teleprompter" : "Pause teleprompter"}
                className={`${styles.transportButton} ${styles.primaryTransport}`}
                onClick={() => setPaused((value) => !value)}
                type="button"
              >
                {paused ? (
                  <svg aria-hidden="true" viewBox="0 0 20 20">
                    <path d="m7 5 7 5-7 5Z" />
                  </svg>
                ) : (
                  <svg aria-hidden="true" viewBox="0 0 20 20">
                    <path d="M6.5 5.5v9M13.5 5.5v9" />
                  </svg>
                )}
              </button>
              <button
                aria-label="Close teleprompter"
                className={styles.transportButton}
                onClick={stop}
                type="button"
              >
                <svg aria-hidden="true" viewBox="0 0 20 20">
                  <rect height="7" rx="1.5" width="7" x="6.5" y="6.5" />
                </svg>
              </button>
            </div>
          </div>
        </div>

        <div className={styles.auditLabel}>
          <span>185 × 32 hardware core</span>
          <span>zero backdrop tint</span>
        </div>
      </div>
    </section>
  );
}
