"""Synthetic edge executable; delegates unrelated Python invocations."""
import os
from pathlib import Path
import sys
import wave
args = sys.argv[1:]
if args and args[0].endswith('edge-tts-words.py'):
    def value(flag):
        for i, arg in enumerate(args):
            if arg.startswith(flag + '='):
                return arg.split('=', 1)[1]
            if arg == flag:
                return args[i + 1]
        raise RuntimeError('missing synthetic TTS argument ' + flag)
    with wave.open(value('--write-media'), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0' * 3200)
    Path(value('--write-metadata')).write_text('')
elif args == ['-c', 'import edge_tts']:
    pass
else:
    os.execv(os.environ['RATCHET_PYTHON'], [os.environ['RATCHET_PYTHON'], *args])
