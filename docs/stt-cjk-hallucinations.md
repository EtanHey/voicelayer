# CJK hallucination candidates

These exact phrases nominate text for the existing acoustic gates. They are
never text-only deletion rules. Spoken audio, uncertain alignment, and the
outro gate's question/fragment guards still preserve the transcript. A whole
all-CJK result under an explicit non-CJK language is also only a candidate;
`auto`, `ja`, `zh`, `ko`, and `yue` do not enable that language-mismatch rule.
Whisper inference already receives the current language in its HTTP `language`
field, including after Settings changes; no fixed startup language is needed.
The CLI uses `-l` and applies the same whole-CJK gate on its finished output.
Without segment timestamps, new CJK candidates are removable only when the
entire recording is dead-device-flat PCM; steady low-gain audio stays intact.

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
establish that exact standalone output. Under `en`/`he` it is still covered by
the acoustically checked whole-result language-mismatch rule. It remains intact
in auto/CJK language mode unless a separately verified exact phrase matches.
