#!/bin/bash
set -euo pipefail
printf 'MODEL\tPID\tRSS_KIB\n'
ps -axo pid=,rss=,command= | awk '
$3 ~ /(^|\/)awk$/ { next }
/whisper-server/ { print "whisper\t" $1 "\t" $2; next }
/mlx_lm.server/ { print "polish\t" $1 "\t" $2; next }
/tts_daemon.py|voicelayer daemon/ { print "qwen3-tts\t" $1 "\t" $2 }
'
