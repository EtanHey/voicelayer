# VoiceBar Audio Fixtures

Shared XCTest audio fixtures for the ecosystem regression harness.

## Files

- `zero_rms.wav`: 3.0s of 16 kHz mono PCM16 silence. Added in Phase 1 to verify zero-RMS timeout handling.
- `clean_speech.wav`: Apple `say` voice `Samantha` speaking "Run the tests and commit the changes", converted to 16 kHz mono PCM16 WAV.
- `high_noise.wav`: 3.0s synthetic pink noise generated with ffmpeg `anoisesrc=color=pink:r=16000:amplitude=0.3`, encoded as 16 kHz mono PCM16 WAV.

## Provenance

```bash
say -o /tmp/voicelayer_clean_speech.aiff "Run the tests and commit the changes" --voice="Samantha"
afconvert /tmp/voicelayer_clean_speech.aiff -d LEI16@16000 -f WAVE clean_speech.wav
ffmpeg -y -f lavfi -i "anoisesrc=color=pink:r=16000:amplitude=0.3" -t 3 -ac 1 -ar 16000 high_noise.wav
```

All fixtures are expected to remain RIFF/WAVE PCM, 16-bit little-endian, mono, 16 kHz.
