# Language roadmap audit (R04 / V31)

Status: **docs only, read-only audit.** Nothing here changes behaviour. The
recommendations in §10 are proposals and have **not** been implemented.

| Field | Value |
|---|---|
| Audited base | `main` @ `1cb914a23411de94007aeba463cdab1f3b6725c6` (fetched inside the cloud session, 2026-11-05) |
| Drift reference | `integration/2.3` @ `531a261ede5d11466920e2249dac0b4045c33c64` (read-only; 261 commits ahead of `main`, 0 behind; merge-base = the `main` head above) |
| Method | `git grep`/`sed` over `src/`, `flow-bar/Sources/`, `docs/`; every claim below cites `file:line` at the audited `main` blob unless labelled **2.3** |
| Not done | no audio, STT, TTS, LID or model inference was run; no Mac/Swift build; no live-app check |

Citation format: `path:line` refers to `main@1cb914a`. The "last touched" column in
§0 is `git log -1 origin/main -- <file>`, so a reviewer can tell how fresh each
cited blob is.

---

## 0. Inventory: every language assumption found

| # | Assumption | Where (main@1cb914a) | Last touched | Default | Hebrew / mixed effect |
|---|---|---|---|---|---|
| L1 | Whisper language comes from **one env var**, `QA_VOICE_WHISPER_LANG`, default `auto` | `src/language-config.ts:127-131` | `a7e3e7f` 2026-11-01 | `auto` → `-l auto` | Whisper picks one language for each decode (§8) |
| L2 | The header comment promises a "config file" tier that does not exist | `src/language-config.ts:125` vs `:127-131` | same | — | No Settings/UI control for language; env only |
| L3 | `auto` mode sends **no prompt at all**: no dev vocab, no user dictionary | `src/language-config.ts:98-102`, `src/stt.ts:2217`, `src/stt.ts:3315-3318` | `3f26fdb` 2026-11-01 | on | `AUTO_PROMPT` (`language-config.ts:62-64`) is dead in production; dictionary terms only act after decoding |
| L4 | CLI comment says "Auto omits -l" but the code passes `-l auto` | `src/stt.ts:2212-2214` vs `src/language-config.ts:93-96` | — | — | Stale comment only (fixed on 2.3, §9) |
| L5 | Primary chunk decode and prompted tail decode **drop** `options.language`/`detectedLanguage` | `src/stt.ts:2894`, `src/stt.ts:2659-2665` | — | latent | Explicit language would be ignored on these decodes (§1.3) |
| L6 | Detected language is never read back; provenance stores the *configured* mode | `src/whisper-server.ts:1513-1515` (request only), `src/input.ts:1159-1178` | `69775b0` | `language_mode: "auto"` | History can't tell a Hebrew decode from an English one |
| L7 | Wispr Flow backend hard-codes `language: ["en"]` | `src/stt.ts:3376`, `scripts/test-wispr-ws.ts:31` | — | opt-in backend | Hebrew forced through English on this backend |
| L8 | Parakeet TDT v3 language set is 25 European languages; **no `he`**; advisory only, never reroutes | `src/parakeet-backend.ts:20-30`, `:160-162`, `:214`; `src/stt.ts:3542-3551` | `a7e3e7f` | opt-in | Hebrew comes out as Latin-script text with no fallback (§2) |
| L9 | Parakeet LID warning is off by default (`VOICELAYER_PARAKEET_LID_WARNING=1`) | `src/parakeet-backend.ts:217-218`, `src/parakeet-lid.ts:9`, `:62-64`, `:73` | `a7e3e7f` | off | Even when on, it only warns |
| L10 | Outro lexicon carries 5 Hebrew phrases + 3 Hebrew single tokens | `src/stt-outro-gate.ts:151-175`, `:189-200` | `69775b0` | on | Hebrew closers are covered; `כן` is a high-risk entry (acoustic veto only) |
| L11 | Caption-gate lexicon is **English only** | `src/stt-caption-gate.ts:12-27` | `bc1d5cb` 2026-10-26 | on | Hebrew caption hallucinations are not covered |
| L12 | Acoustic filler removal: English `um/uh/er` + Hebrew `אמ/אה`; aggressive hedges English only | `src/rules-engine.ts:134-142`, `:147-154` | `69775b0` | on (aggressive off) | Bilingual on acoustic fillers; English only on hedges |
| L13 | Spoken punctuation / dictation commands are English words only | `src/rules-engine.ts:184-244` | same | on | "נקודה", "פסיק", "שורה חדשה" are not commands |
| L14 | Spoken enumerators are English only (`one,`/`first,`/`next,`…) | `src/rules-engine.ts:1365-1408` | same | on | Hebrew lists (`אחד,` `ראשית,`) never get numbered |
| L15 | Auto-capitalization is `[a-z]` based | `src/rules-engine.ts:1194-1215` | same | on | No-op on Hebrew; fine, and nothing is lost |
| L16 | Aliases use Unicode boundaries and Hebrew proclitic handling | `src/rules-engine.ts:1266-1300`, `src/stt-cleanup.ts:38-51` | same | on | The one piece built for code-switching (Hebrew-script tech terms → Latin) |
| L17 | "one" normalization is English only | `src/stt-cleanup.ts:711-715` | `69775b0` | on | Harmless on Hebrew |
| L18 | Terminal punctuation floor: question detection is English words only | `src/stt-punctuation.ts:25-49`, `:50`, `:105`, `:250-268`; called at `src/input.ts:448-463` | `bc1d5cb` | on | A Hebrew question without its `?` gets `.` and never `?` |
| L19 | LLM polish prompt is explicitly bilingual | `src/stt-polish.ts:268-276` | `69775b0` | optional | Says "Preserve Hebrew as Hebrew" |
| L20 | TTS default voice `en-US-JennyNeural`; short/long profile chosen by **length only** | `src/tts-settings.ts:12`, `:118-140`; `src/tts.ts:95` | `bc1d5cb` / `7c3a0f2` | on | No step anywhere picks a voice by language |
| L21 | Clone→Edge fallback goes to the profile's `fallback` or Jenny | `src/tts.ts:223`, `:2407`, `:3006`, `:3135-3141`; `src/tts/qwen3.ts:259` | `7c3a0f2` / `5054ed2` | on | A Hebrew `voice_ask` question falls back to an en-US voice (§7) |
| L22 | XTTS tier hard-codes `language="en"` | `src/tts/xtts.ts:150` | `92bd302` | only when a fine-tuned model is present | Hebrew text is synthesized as English |
| L23 | Clone word-timing alignment picks `he` if **any** Hebrew char, else `en` | `src/tts/clone-timing.ts:53` | `70c2676` | on | A mixed chunk is aligned entirely as Hebrew |
| L24 | Speakable-text keeps Hebrew lines verbatim and leaves digit-reading to the voice | `src/speakable-text.ts:368-369`, `:391-392` | `b16e403` | on | Correct for a Hebrew voice; with an en-US voice the reading is unknown (UNRUN) |
| L25 | Edge voice picker lists en-US voices only (one "multilingual") | `src/tts-controls-status.ts:46`, `flow-bar/Sources/VoiceBarUI/SpeechSettingsView.swift:241` | `5613da6` / `80a8379` | — | No Hebrew voice offered in UI |
| L26 | `voice_ask` 600-char cap was sized with Hebrew in mind | `src/handlers.ts:146`, `:156` | `0759485` | 600 | ~712 Hebrew chars fit one teleprompter frame; the cap holds in both scripts |

---

## 1. STT language selection (Whisper)

### 1.1 The single source of truth
`getLanguageModeFromEnv()` reads only `process.env.QA_VOICE_WHISPER_LANG`; unset,
empty or unrecognised → `"auto"` (`src/language-config.ts:115-121`, `:127-131`).
`getLanguageConfig()` always emits `-l <code>` (`:93-96`) and adds `--prompt` only
when the mode is not `auto` (`:98-102`). No production caller sets
`STTTranscribeOptions.language`/`detectedLanguage`. The only definition is the
contract at `src/soundlayer/contracts.ts:43-48`, and `git grep` finds no
production writer, so in practice every decode follows L1.

### 1.2 Callers
- **whisper.cpp CLI** (`WhisperCppBackend`, `src/stt.ts:2164`): builds args at
  `src/stt.ts:2215-2246`. An explicit request language would overwrite the `-l`
  value (`:2225-2228`). The prompt is empty in auto (`:2217`).
- **whisper-server (resident, default)**: the server is spawned with no language
  (`src/whisper-server.ts:508-522`). The language is a per-request multipart field
  (`:1513-1515`) built by `buildWhisperServerOptions` (`src/stt.ts:3306-3331`),
  which sends `language=auto` by default (`:3325-3326`) and no prompt in auto (`:3315-3318`).
- **Parakeet's Whisper fallback** is a CLI backend with `noVocabularyPrompt: true`
  (`src/stt.ts:3531`, `:3548`), so it also runs in auto with no prompt.
- **Backend auto-pick order**: resident server → CLI → Wispr (`src/stt.ts:3588-3607`).

### 1.3 Latent inconsistency in the ≥90 s chunked path (L5)
Most re-decodes spread `...options` into `buildWhisperServerOptions`
(`src/stt.ts:2420`, `:2570`, `:2679`, `:2747`, `:2927`, `:2937`, `:3038`, `:3228`, `:3288`).
Two do not:
- `src/stt.ts:2894`: the **primary per-chunk decode** passes only `{ promptOverride }`.
- `src/stt.ts:2659-2665`: the prompted tail verification passes only `{ promptOverride }`.

Today this changes nothing, because nobody passes a language (§1.1). The day a caller
does (for example a future per-request or LID-driven language), the chunk body would
decode in `auto` while the head, tail and witness decodes use the explicit language.
That would produce different scripts on either side of a seam (§8.3).

### 1.4 Provenance (L6)
The archive records `language_mode` = the configured mode (`src/input.ts:1159-1178`,
`src/recording-provenance.ts:100`, `:641`, `:685`), never the language Whisper
actually detected. The server response's language field is never parsed
(`git grep language src/whisper-server.ts` → request side only). So the History tab
can't separate Hebrew decodes from English ones.

### 1.5 Wispr Flow (L7)
`WisprFlowBackend` sends `{"type":"auth","language":["en"]}` (`src/stt.ts:3376`).
It is opt-in (`QA_VOICE_STT_BACKEND=wispr` or the last auto fallback), and it is the only
STT path with a hard-coded language.

---

## 2. Parakeet: "English-only" premise, corrected

The task brief calls Parakeet English-only. The current code says something more specific:
- `PARAKEET_LANGUAGES` = `en es fr de bg hr cs da nl et fi el hu it lv lt mt pl pt ro sk sl sv ru uk`
  (`src/parakeet-backend.ts:20-21`): the v3 model-card list. **Hebrew is absent.**
- `parakeetLanguage()` reads `options.language ?? QA_VOICE_WHISPER_LANG ?? "auto"`
  (`:23-30`). An unsupported explicit language (e.g. `he`) is returned as-is so that
  it **warns** (`:28`, `:160-162`). Auto yields the `auto-language-unverified` warning.
- The selection is authoritative: "fallback is for failed/incomplete responses, never
  an automatic language or prompt-based switch" (`src/stt.ts:3549-3550`). The
  advisory is logged and the selected recognizer is kept (`src/parakeet-backend.ts:214`).
- The docs agree: "Parakeet may render unsupported speech as plausible Latin text"
  (`docs/parakeet-resident-backend.md:61`). Even explicit Hebrew hints stay advisory
  (`:185`).
- The LID probe (whisper `ggml-small`, `-dl -l auto`, first ≤30 s) is off unless
  `VOICELAYER_PARAKEET_LID_WARNING=1` (`src/parakeet-backend.ts:217-218`;
  `src/parakeet-lid.ts:9-10`, `:62-64`, `:73`). Even when on, it never changes
  the engine or the delivered text.
- The VoiceBar picker copy has no language warning (`flow-bar/Sources/VoiceBarUI/RecognizerPickerState.swift:9`, `:240-258`).

**Net:** with Parakeet selected, Hebrew speech is decoded by a model with no Hebrew
support, and nothing routes it to Whisper. "English-only" is wrong as a code claim,
but in effect it is **not Hebrew-capable**.

---

## 3. Hallucination gates: Hebrew vs English lexicons

### 3.1 Outro gate (`src/stt-outro-gate.ts`, default on)
- Phrases (`:151-175`): 18 English entries, 5 Hebrew (`תודה`, `תודה רבה`,
  `תודה רבה לכם`, `להתראות`, `ביי ביי`, at `:169-174`), added on the owner's 2026-09-06
  ruling (`:147-149`).
- Single tokens (`:189-200`): 7 English, 3 Hebrew (`תודה`, `ביי`, `כן`). The source
  itself flags `כן` as "the riskiest entry here" (`:183-187`). Only the acoustic
  conditions protect a real spoken "yes".
- Normalisation is Unicode-aware (`\p{L}\p{N}`, `:303-309`). Sentence split is
  `[.!?:;]`/ellipsis followed by whitespace (`:341-349`). Hebrew text uses the same
  ASCII marks, so the split works for Hebrew.
- The gate applies in **every** language mode. Language never decides a removal,
  only the lexicon plus audio (`:389-390` and the acoustic checks).
- Main runs it only in `WhisperServerBackend` (`src/stt.ts:2360-2366`, `:2415`,
  `:2485`). The CLI backend, which includes Parakeet's fallback, has no outro gate
  on main (2.3 adds one, §9).

### 3.2 Caption gate (`src/stt-caption-gate.ts`, same switch)
`CAPTION_PREFIXES` (`:12-27`) is English credit captions plus a bare `you`. There
are **no Hebrew entries**. Whisper's Hebrew caption hallucinations over silence are
not covered (examples would be subtitle-credit or "thanks for watching" forms; any
specific phrase list needs corpus evidence first, see §10 R5).

---

## 4. Rules engine (`src/rules-engine.ts`, via `cleanupTranscriptionText` at `src/stt-cleanup.ts:640-657`)

| Stage | Lines | Language reality |
|---|---|---|
| Acoustic fillers | `:134-142` | English `um/uh/er` (ASCII `\b`) **and** Hebrew `אמ`/`אה` with whitespace guards (`:137-141` explains `אמש`/`אמת`/`אהבה` safety). Bilingual. |
| Aggressive hedges | `:147-154` | English only (`basically`, `kind of`, `like …`). Off by default. |
| Spoken punctuation | `:184-244` (`ALWAYS_PUNCTUATION_MAP`, `AMBIGUOUS_PUNCTUATION_MAP`) | English command words only; `spokenPhraseOf` asserts `^[a-z]+( [a-z]+)*$` (`:295-300`). No Hebrew dictation commands. |
| Tech vocab / code tokens | `:112-118`, `:1145+` | English/code. Language-neutral in effect. |
| Aliases | `:1266-1300` | Unicode boundaries; Hebrew→Latin aliases may absorb a Hebrew proclitic (`ו?[בהכלמש]`, `:1266-1267`). Built-in Hebrew-script tech aliases plus a context guard for `פרונט/בק/בבל` (`src/stt-cleanup.ts:38-51`). **The only stage designed for code-switching.** |
| Numbers | `:1089+` | English number words |
| Enumerators | `:1365-1408` | English heads only (`one…ten`, `first…tenth`, `next`, `then`, `finally`, `\d{1,2}`). Hebrew ordinals and counts are not recognised, so a Hebrew spoken list stays prose. |
| Capitalization | `:1194-1215` | `[a-z]` only; a safe no-op on Hebrew. |

`normalizeConversationalOne` (`src/stt-cleanup.ts:711-715`) is English only and harmless.

## 5. Terminal punctuation floor (`src/stt-punctuation.ts`)
It runs on every finalized transcript (`src/input.ts:448-463`). It appends `.` or
`?` only when the text has no terminal mark (`:250-268`). `?` requires an English
interrogative opener or an aux+subject pair (`INTERROGATIVE_OPENERS` `:25-49`,
`QUESTION_AUX_OPENERS` `:50`, `QUESTION_SUBJECTS` `:105`). A Hebrew question
(`מה`, `איך`, `למה`, `האם` …) that Whisper left unpunctuated gets `.`. This follows
the owner's law (never upgrade without an interrogative signal) but is English-blind.

## 6. Polish
The optional LLM polish prompt is explicitly bilingual: it adds "Hebrew/English
spacing" and says "Preserve Hebrew as Hebrew and English/code terms as English"
(`src/stt-polish.ts:268-276`). It is not a language-routing surface.

---

## 7. TTS voice selection, including the Hebrew `voice_ask` fallback

- **Profile selection** depends only on length: `text.length > short_limit_chars (400)`
  → `long`, else `short` (`src/tts-settings.ts:136-140`). The voice comes from
  `QA_VOICE_TTS_VOICE` > settings file > `en-US-JennyNeural` (`:12`, `:118-133`).
- `voice_ask` speaks its question through the same `speak()` (`src/handlers.ts:871-875`,
  `mode: "converse"` → `src/tts.ts:2942-2952`). Nothing in it detects language.
- **Hebrew ask fallback path**, as it exists today. Main has no Hebrew-specific
  fallback; `git grep -i hebrew` over `src/tts*`, `src/tts/`, `flow-bar/Sources` and
  `src/tts_daemon.py` finds none, on both main and 2.3. The fallbacks that do exist
  all pick an English voice:
  1. Clone profile missing → `TTS_DEFAULTS.voice` (Jenny) (`src/tts.ts:2948-2951`, `:2366-2367`).
  2. Clone synthesis unavailable → `resolved.fallbackVoice || defaultVoice()`
     (`src/tts.ts:3135-3141`). `fallbackVoice` = the profile's `fallback`, else
     `defaultVoice()` (`:223`). A Qwen3 profile with no `fallback` gets Jenny
     (`src/tts/qwen3.ts:259`).
  3. Short `announce` shortcut (<50 chars) → the same fallback voice (`src/tts.ts:2998-3009`).
  4. Long-read chunk fallback → the same chain (`src/tts.ts:2407`).
- **Raw voice override**: any `xx-YY-…` name passes through (`src/tts.ts:243-246`).
  A caller *can* pass `he-IL-…` per call, but no code chooses it for them.
- **UI**: the Edge voice list is six en-US voices, one of them "multilingual"
  (`src/tts-controls-status.ts:46`; `SpeechSettingsView.swift:241`).
- **XTTS** tier: `language="en"` is fixed (`src/tts/xtts.ts:150`).
- **Speakable text** keeps Hebrew lines intact and doesn't inject English number words
  into them (`src/speakable-text.ts:368-369`, `:391-392`). That assumes the voice can
  read Hebrew.
- **Clone alignment** (teleprompter timing) chooses `he` if any Hebrew char is
  present, else `en` (`src/tts/clone-timing.ts:53`). A mixed chunk is aligned as one
  language.

How an en-US Edge voice (or a Qwen3 clone) actually *sounds* on Hebrew text was **not
measured** (no audio allowed). This audit only shows that the code never selects a
Hebrew-capable voice.

---

## 8. Why mixed Hebrew/English fails: an end-to-end trace

Default stack: resident whisper-server, `QA_VOICE_WHISPER_LANG` unset.

1. **One language per decode.** The request carries `language=auto` and no prompt
   (`src/stt.ts:3315-3326`). In whisper.cpp, `auto` runs language detection and then
   decodes the window under that single language token. This is external model
   behaviour and was not measured here. The repo already treats it as known: see the
   R1 note at `src/language-config.ts:9-12` and the Parakeet docs at
   `docs/parakeet-resident-backend.md:204-209`. A code-switched utterance is decoded as
   one language, so minority-language words tend to come out transliterated into the
   majority script, or translated.
2. **No vocabulary priming in auto.** Auto drops the dev/dictionary prompt (L3).
   English tech terms spoken inside Hebrew speech have nothing pulling them toward
   Latin spelling.
3. **Post-decode repair covers only part of it.** The Hebrew→Latin alias table
   (`src/stt-cleanup.ts:38-51`, `src/rules-engine.ts:1266-1300`) maps a fixed set of
   Hebrew-script tech words back to Latin. Anything outside it stays in the wrong
   script. Nothing repairs Latin-transliterated Hebrew.
4. **Each ≥90 s chunk detects its language on its own.** Every chunk is a separate
   request (`src/stt.ts:2894`), so detection can differ between neighbouring chunks.
   The seam merge matches words across the 5 s overlap. If one side decoded the
   overlap in Hebrew script and the other in Latin, there are no shared tokens. That
   matches the "duplicate or dropped overlap" family of failures named in AGENTS.md.
   **Hypothesis, UNRUN:** this needs a synthetic mixed-language fixture to confirm.
5. **Text stages are mostly English-only.** Dictation commands, enumerators and the
   question floor (§4-§5) don't fire on Hebrew segments. Fillers and the outro gate do.
6. **Provenance hides it.** `language_mode: "auto"` is all that gets recorded (L6).
7. **With Parakeet selected**, step 1 is worse: Hebrew isn't in the model's languages
   and the advisory never reroutes (§2).
8. **Speaking back.** A Hebrew or mixed `voice_ask` question is spoken by Jenny or the
   clone, falling back to Jenny (§7).

---

## 9. `integration/2.3` drift (label: **2.3**)

Language-relevant diffs `main...integration/2.3` (`git diff --shortstat`):
`language-config.ts`, `stt-punctuation.ts`, `tts-settings.ts`, `parakeet-lid.ts`,
`whisper-server.ts`: **no change**. Changed:

- **2.3 · CJK hallucination gate** (commit `4e3415a`, "acoustically gate CJK captions and
  language mismatches"): `CJK_HALLUCINATION_PHRASES` (2.3 `src/stt-outro-gate.ts:153`),
  `ExplicitOutroLanguage = "en" | "he"` (`:327`), `isCjkLanguageMismatch` (`:330`), CJK
  terminal marks in `splitSentences`; caption gate adds a `cjk-caption` class (2.3
  `src/stt-caption-gate.ts:13`, `:205`). The mismatch rule is enabled **only** when
  the language is explicitly `english`/`hebrew`. 2.3 `src/stt.ts:86-91`,
  `explicitOutroLanguageSetting()`, reads `QA_VOICE_WHISPER_LANG` and returns
  `undefined` for auto. So under the default `auto`, only the exact CJK phrase list applies.
- **2.3 · CLI outro gate**: `WhisperCppBackend` now runs `stripHallucinatedOutro` (2.3
  `src/stt.ts:2311-2314`). On main it runs only in the server backend (§3.1). That
  closes the Parakeet-fallback gap.
- **2.3 · stale comment fixed**: "Auto passes -l auto explicitly" (2.3 `src/stt.ts:2227`), resolving L4.
- **2.3 · rules-engine**: possessive alias sources (`possessiveAliasSources`). English
  possessive clitics, scoped to user-store aliases. Hebrew handling is unchanged.
- **2.3 · parakeet-backend**: Silero-based uncovered-tail and `ACOUSTIC_GATE_EMPTY`
  outcome. **No language change**; `PARAKEET_LANGUAGES` and advisory-only routing are the same.
- **2.3 · teleprompter RTL** coverage (commit `09fd3e5`): display only, not in this audit's scope.
- Still identical on 2.3: L1-L3, L5-L9, L11-L18, L20-L25. No Hebrew TTS voice
  routing and no Hebrew caption entries.

---

## 10. Recommendations (NOT implemented; each needs its own PR and owner sign-off)

Ordered by what most directly protects "what comes out is what I actually said".
Every item has to respect the AGENTS.md law: never lose words, and raw-accurate over tidy.

- **R1 Record the detected language.** Parse the language Whisper reports and store it
  next to `language_mode` (L6). This is read-only provenance and a prerequisite for
  measuring anything below.
- **R2 Thread an explicit language through every decode.** Make `src/stt.ts:2894` and
  `:2659` spread `options` like their siblings (L5), with a test that fails on today's
  code. That test is an ordinary unit test on `buildWhisperServerOptions` call shape.
- **R3 Measure mixed-language decoding before changing defaults.** Build a synthetic,
  non-private bilingual fixture set. Compare `auto` against forced `he`/`en`, with
  and without the bilingual `AUTO_PROMPT` (L3), across the chunk-seam path (§8.4).
  Don't flip the default on intuition: auto-no-prompt exists to prevent silence
  hallucinations (`src/language-config.ts:98-99`).
- **R4 Parakeet + Hebrew.** At minimum, surface the existing advisory in the
  recognizer picker. Whether a high-confidence non-supported LID result should
  *offer* (not force) Whisper is a product decision for the owner, since the current
  contract says selection is authoritative (`docs/parakeet-resident-backend.md:57-62`).
- **R5 Hebrew caption entries.** Add Hebrew caption-hallucination phrases **only**
  from archived evidence (as was done for `תודה.`, `src/stt-outro-gate.ts:147-149`),
  behind the same acoustic gate. Re-review `כן` as a single token with corpus counts.
- **R6 Hebrew question floor.** Add Hebrew interrogative openers (`מה`, `מי`, `איך`,
  `למה`, `מתי`, `איפה`, `האם`, `כמה`) to the punctuation floor. This is additive and
  only affects text that has no terminal mark.
- **R7 Hebrew dictation commands and enumerators.** Treat these as optional and gated,
  with the same noun-vs-command evidence rules as the English map
  (`src/rules-engine.ts:168-181`) so they don't eat words.
- **R8 Language-aware TTS voice.** Add an optional per-profile `hebrew_voice` (or
  script-based selection to a configured `he-IL-*`/multilingual voice). Make clone
  fallback honour it, so a Hebrew `voice_ask` question isn't read by an en-US voice
  (§7). Keep it opt-in until verified on the real app.
- **R9 Housekeeping.** Remove the "config file" claim (L2). Fix the stale CLI comment
  on main (L4, already done on 2.3). Make Wispr's language follow L1 instead of
  `["en"]` (L7). Decide whether XTTS's fixed `en` (L22) should be documented or removed.
- **R10 Land 2.3 language deltas deliberately.** The CJK/explicit-language gate and the
  CLI outro gate (§9) change deletion behaviour. Their verification belongs to the 2.3
  release, not this audit.

---

## 11. Proof, limitations, UNRUN

- **Proof type:** static source evidence only. Every row is a `file:line` at
  `main@1cb914a` (or labelled 2.3 @ `531a261`). Commands used: `git fetch origin main
  integration/2.3`, `git rev-parse`, `git grep -n`, `sed -n`, `git diff --shortstat
  origin/main origin/integration/2.3 -- <file>`, `git log -1 origin/main -- <file>`,
  `git rev-list --count`.
- **UNRUN:** no `bun test` (docs-only change); no STT/TTS/LID/inference; no audio; no
  macOS/Swift build; no live VoiceBar.
- **External-behaviour claims** (Whisper's per-window language token, what an en-US
  Edge voice does with Hebrew) are labelled as unmeasured.
- **Not audited:** the Python TTS daemon's Qwen3 language handling beyond "the repo
  passes no language field" (`git grep -i lang src/tts_daemon.py` → none). Swift
  teleprompter RTL layout. BrainLayer history (not reachable from the cloud session).
