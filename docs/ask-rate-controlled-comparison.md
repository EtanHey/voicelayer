# Controlled Ben narration comparison

Status: experiment complete; proposed long-request acceleration cause not confirmed.

Sixteen sequential HTTP synthesis requests completed on 2026-11-08, with no playback. Each request passed recorder, VoiceBar idle, session-lock age and HID idle checks. Ben used the same reference and model at +0%. Identical request texts were reused across arms to fit the 16-request cap. This is one sample per unique request, not a variance estimate.

| Words | Arm | Requests | Audio seconds | Added pause seconds | WPM excluding added pauses | WPM including added pauses |
|---:|---|---:|---:|---:|---:|---:|
| 26 | whole | 1 | 8.00 | 0.00 | 195.0 | 195.0 |
| 26 | read | 2 | 8.64 | 0.00 | 180.6 | 180.6 |
| 26 | bounded | 2 | 8.64 | 0.55 | 180.6 | 169.7 |
| 53 | whole | 1 | 16.88 | 0.00 | 188.4 | 188.4 |
| 53 | read | 4 | 19.28 | 0.00 | 164.9 | 164.9 |
| 53 | bounded | 5 | 18.24 | 1.90 | 174.3 | 157.9 |
| 86 | whole | 1 | 29.84 | 0.00 | 172.9 | 172.9 |
| 86 | read | 5 | 29.44 | 0.00 | 175.3 | 175.3 |
| 86 | bounded | 8 | 28.88 | 3.55 | 178.7 | 159.1 |

Audio durations were measured with ffprobe. Added silence is separately accounted for mathematically; it is not playback timing. Whole means one synthesis request. Read uses the production chunkTextForLongRead clone path with rate +0%, without extra synthetic gaps for plain prose. Bounded uses NarrationLayer planning with a maximum of 14 words, minimum of one word to enforce that hard cap, 0.55-second sentence pauses and 0.25-second clause pauses. Its largest actual utterance is 13 words. The minimum differs from NarrationLayer default three, so this arm must not be described as an exact default-NarrationLayer replay.

## Conclusion

The 26- and 53-word whole requests were faster than their read counterparts, but the 86-word whole request was slightly slower. Whole-request WPM decreased as text length increased in this sample. The hypothesis that long single requests systematically accelerate Qwen was not confirmed. Bounded synthesis without added pauses remained around 174 to 181 WPM; added pauses produced 158 to 170 WPM. This establishes an audible-duration effect of pause policy, not that missing pauses caused the historical incident.

No production change or claimed after-fix WPM is justified by this experiment alone. There is no fail-first production regression test because the proposed defect did not reproduce consistently. The earlier telemetry patch remains the means to capture future incident provenance. Engine order, reference choice and blanket rate changes are unsupported remedies.

## Neutral source texts

1. The small public library opens early each morning and welcomes every local visitor. Inside the reading tables offer quiet spaces for planning a useful community project.

2. The small public library opens early each morning and welcomes every local visitor. Inside the reading tables offer quiet spaces for planning a useful community project. A volunteer checks the calendar carefully before arranging chairs beside the large window. Later, the group compares several ideas and chooses one practical task for the afternoon.

3. The small public library opens early each morning and welcomes every local visitor. Inside the reading tables offer quiet spaces for planning a useful community project. A volunteer checks the calendar carefully before arranging chairs beside the large window. Later, the group compares several ideas and chooses one practical task for the afternoon. Everyone brings a notebook ready to record the next steps clearly. The meeting ends calmly with enough time for a short walk. Outside the garden paths lead past flowers toward the open square.

## Per-request measurements

| Request | Words | Seconds | WPM |
|---:|---:|---:|---:|
| 1 | 26 | 8.00 | 195.0 |
| 2 | 13 | 4.48 | 174.1 |
| 3 | 13 | 4.16 | 187.5 |
| 4 | 53 | 16.88 | 188.4 |
| 5 | 17 | 6.48 | 157.4 |
| 6 | 9 | 4.00 | 135.0 |
| 7 | 14 | 4.32 | 194.4 |
| 8 | 13 | 4.40 | 177.3 |
| 9 | 1 | 0.48 | 125.0 |
| 10 | 13 | 4.72 | 165.3 |
| 11 | 86 | 29.84 | 172.9 |
| 12 | 28 | 8.48 | 198.1 |
| 13 | 19 | 6.00 | 190.0 |
| 14 | 11 | 3.84 | 171.9 |
| 15 | 11 | 3.04 | 217.1 |
| 16 | 11 | 3.76 | 175.5 |
