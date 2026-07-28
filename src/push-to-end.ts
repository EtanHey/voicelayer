import { appendControlLayerEvent } from "./control-layer-journal";

export const PUSH_TO_END_GATE_ENV = "VOICELAYER_ALLOW_PUSH_TO_END";

interface PushToEndPolicyOptions {
  caller: string;
  env?: Record<string, string | undefined>;
  warn?: (message: string) => void;
  appendEvent?: typeof appendControlLayerEvent;
}

function defaultWarning(message: string): void {
  console.error(message);
}

export function warnLegacyPressToTalk(
  caller: string,
  warn: (message: string) => void = defaultWarning,
): void {
  warn(
    `[voicelayer] Deprecated press_to_talk ignored; use push_to_end (caller: ${caller}).`,
  );
}

export function resolvePushToEnd(
  requested: boolean,
  options: PushToEndPolicyOptions,
): boolean {
  if (!requested) return false;

  const env = options.env ?? process.env;
  const warn = options.warn ?? defaultWarning;
  if (env[PUSH_TO_END_GATE_ENV] !== "1") {
    warn(
      `[voicelayer] push_to_end ignored: ${PUSH_TO_END_GATE_ENV}=1 is required; ` +
        `use manual-stop mode only when the user explicitly asked for it (caller: ${options.caller}).`,
    );
    return false;
  }

  const appendEvent = options.appendEvent ?? appendControlLayerEvent;
  appendEvent(
    "capture.push_to_end_honored",
    {
      caller: options.caller,
      push_to_end: true,
    },
    { topic: "voice.input" },
  );
  return true;
}
