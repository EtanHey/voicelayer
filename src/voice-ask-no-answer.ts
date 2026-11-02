/** Default no-answer budget; explicit timeout_seconds overrides this setting. */
export function voiceAskNoAnswerSeconds(): number {
  const raw = process.env.VOICELAYER_ASK_NO_ANSWER_SECONDS;
  const seconds = Number(raw);
  return raw?.trim() && Number.isFinite(seconds) && seconds >= 5 && seconds <= 3600
    ? seconds : 120;
}
