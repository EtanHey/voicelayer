"use client";

import dynamic from "next/dynamic";

const VoiceDemo = dynamic(
  () =>
    import("@/components/voice-demo").then((m) => ({ default: m.VoiceDemo })),
  { ssr: false, loading: () => <div className="py-20" /> },
);

export function VoiceDemoLoader() {
  return <VoiceDemo />;
}
