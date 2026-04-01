const STATS = [
  { value: "<1.5s", label: "transcription" },
  { value: "150 WPM", label: "speech vs 40 typing" },
  { value: "HE + EN", label: "bilingual" },
  { value: "On-device", label: "whisper.cpp" },
];

export function Stats() {
  return (
    <div className="mx-auto max-w-[960px] px-6">
      <div className="flex justify-center gap-12 py-8 flex-wrap max-md:gap-6">
        {STATS.map((s) => (
          <div key={s.label} className="flex flex-col items-center gap-1">
            <span className="font-mono text-lg font-semibold text-accent">
              {s.value}
            </span>
            <span className="text-xs text-text-dim font-light uppercase tracking-[0.06em]">
              {s.label}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
