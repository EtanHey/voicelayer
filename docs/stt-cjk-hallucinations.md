# CJK hallucination candidates

These exact phrases nominate text for the existing acoustic gates. They are
never text-only deletion rules. The only non-lexicon candidate is one complete
all-CJK sentence, at most 20 CJK characters, under the user's explicit English
or Hebrew setting. Multiple sentences and longer results stay intact. Questions,
fragments, speech-level energy, uncertain alignment and clearance failures keep
the words. Without timestamps, removal additionally needs dead-device-flat PCM.

`ExplicitOutroLanguage` is only `en | he`. The gate's setting resolver accepts no
transcription options: `detectedLanguage` and per-decode hints cannot activate
it for `auto`. Decode language is independently sent by HTTP `language` or CLI
`-l`. The CLI returns `EMPTY_RESPONSE`, never `RETURNED`, when gating empties its
text, with a phrase-free `gateRemoval` fact (gate, span count, raw character
count). Archives retain this fact and a closing-phrase filter explanation in
History's existing diagnostic detail without storing removed words there.

Sources checked 2026-11-02:

| Exact candidate | Evidence |
| --- | --- |
| ご視聴ありがとうございました | [Noise-only Whisper dataset](https://huggingface.co/datasets/sachaarbonel/whisper-hallucinations), `phrases.csv`, `ja` count 3 |
| ご視聴ありがとうございます | Same dataset, `ja` count 1 |
| チャンネル登録をお願いします | [First-hand large-v3-turbo transcription report](https://ryusei.io/article/subtitle-burn-in-browser), hallucination section, reproduced over music/BGM |
| 请不吝点赞 订阅 转发 打赏支持明镜与点点栏目 | [Whisper discussion #2244](https://github.com/openai/whisper/discussions/2244), first-hand v2/v3 report including background-noise input |
| 谢谢观看 | Noise-only dataset, `zh` and `haw` count 1 |
| 感谢观看 | Noise-only dataset, `zh` count 1 |
| 字幕由Amara.org社区提供 | Noise-only dataset, normalized as `字幕由amara org社区提供`, `zh`, `bo`, `my` count 1 |
| 시청해주셔서 감사합니다 | Noise-only dataset, `ko` count 2; [first-hand report](https://github.com/PocketShell-io/pocketshell/issues/452) |

The requested standalone `字幕` is deliberately absent from the exact-phrase
lexicon: the sources verified caption-credit phrases containing it, but did not
establish that exact standalone output. The bare fragment stays intact; `字幕。` can be a bounded mismatch candidate
under explicit `en`/`he`. Auto retains it unless a verified exact phrase matches.
