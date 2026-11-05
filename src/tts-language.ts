/** Count letters rather than punctuation, digits or Hebrew vowel marks. */
export function edgeVoiceForText(text: string, voice: string): string {
  if (!/^en-[A-Z]{2}-.+Neural$/.test(voice)) return voice;
  const letters = [...text].filter(char => /\p{Letter}/u.test(char));
  const hebrew = letters.filter(char => /\p{Script=Hebrew}/u.test(char)).length;
  return hebrew > letters.length / 2 ? "he-IL-HilaNeural" : voice;
}
