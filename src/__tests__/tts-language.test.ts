import { expect, it } from "bun:test";
import { edgeVoiceForText } from "../tts-language";

for (const text of ["האם אפשר להמשיך?", "123 🙂 … האם להמשיך עם TypeScript?", "הַאִם אֶפְשָׁר?"]) {
  it(`routes predominantly Hebrew letters to Hila: ${text}`, () => {
    expect(edgeVoiceForText(text, "en-US-JennyNeural")).toBe("he-IL-HilaNeural");
    expect(edgeVoiceForText(text, "en-GB-SoniaNeural")).toBe("he-IL-HilaNeural");
  });
}
for (const text of ["Can we continue?", "Use שלום in the greeting", "123 🙂 …", "مرحبا"]) {
  it(`preserves the English voice when Hebrew is not predominant: ${text}`, () => {
    expect(edgeVoiceForText(text, "en-US-JennyNeural")).toBe("en-US-JennyNeural");
  });
}
it("preserves selected Hebrew, other-language and clone profile names", () => {
  for (const voice of ["he-IL-AvriNeural", "fr-FR-DeniseNeural", "my-clone"]) {
    expect(edgeVoiceForText("האם אפשר להמשיך?", voice)).toBe(voice);
  }
});
