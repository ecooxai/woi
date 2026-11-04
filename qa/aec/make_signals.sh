#!/bin/bash
# Builds the far-end / near-end test signals for the AEC measurement
# (24 kHz mono s16 WAV) into $1.
set -euo pipefail
out=$1; fx=$(cd "$(dirname "$0")/../../research/fixtures" && pwd)
mkdir -p "$out"
ff() { ffmpeg -loglevel error -y "$@"; }
# "Music": a chord progression with harmonics plus noise-burst percussion, 12 s.
ff -f lavfi -i "aevalsrc='0.18*(sin(2*PI*220*t)+0.5*sin(2*PI*440*t)+0.6*sin(2*PI*277.2*t)+0.5*sin(2*PI*329.6*t)+0.3*sin(2*PI*(110+55*floor(mod(t,4)))*t))*(0.6+0.4*sin(2*PI*0.5*t))':s=24000:d=12" \
  -f lavfi -i "anoisesrc=c=pink:r=24000:a=0.25:d=12" \
  -filter_complex "[1]volume='if(lt(mod(t,0.5),0.06),1,0.05)':eval=frame[d];[0][d]amix=inputs=2:normalize=0,alimiter=limit=0.8" \
  -ac 1 -ar 24000 -c:a pcm_s16le "$out/music.wav"
# "Video" speech: other fixtures, pitch-shifted so it is a different voice.
ff -i "$fx/08_complex_task.wav" -i "$fx/06_edit_notes.wav" -i "$fx/05_show_readme.wav" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1,asetrate=24000*0.85,aresample=24000" -ac 1 -c:a pcm_s16le "$out/farspeech.wav"
# Near-end (the user): two fixtures with a pause.
ff -i "$fx/01_hello.wav" -f lavfi -t 0.8 -i "anullsrc=r=24000:cl=mono" -i "$fx/04_run_ls_home.wav" \
  -filter_complex "[0][1][2]concat=n=3:v=0:a=1" -ac 1 -c:a pcm_s16le "$out/near.wav"
