#!/usr/bin/env bash
# Reproduction silencieuse : sortie par défaut = BlackHole (muet), cadence changée 48k -> 24k en plein enregistrement.
# usage : test-rate.sh <dossier> [env supplémentaires…]
set -u
S="$(cd "$(dirname "$0")" && pwd)"; OUT="$1"; shift
BH=BlackHole64ch_UID
ORIG=$($S/audiodev get)
$S/audiodev rate $BH 48000 >/dev/null; $S/audiodev set $BH >/dev/null; sleep 0.5
echo "sortie : $($S/audiodev get)"
( sleep 1; say -v Thomas -r 190 "Un deux trois quatre cinq six sept huit neuf dix, onze douze treize quatorze quinze seize dix-sept dix-huit dix-neuf vingt, vingt-et-un vingt-deux vingt-trois vingt-quatre vingt-cinq vingt-six vingt-sept vingt-huit vingt-neuf trente." ) &
( sleep 5; echo "-> cadence BlackHole : $($S/audiodev rate $BH ${RATE:-16000})" ) &
env "$@" "$(dirname "$S")/../.build/debug/notekeeper-audiotest" "$OUT" 11 2>&1 | grep -E "audio:|system.wav|avertissement|ERREUR" | cut -c1-230
wait
$S/audiodev rate $BH 48000 >/dev/null; $S/audiodev set "$ORIG" >/dev/null
echo "restauré : $($S/audiodev get)"
python3 - "$OUT/system.wav" <<'PY'
import sys, wave, array, numpy as np
w=wave.open(sys.argv[1]); sr=w.getframerate(); a=np.array(array.array('h', w.readframes(w.getnframes())),dtype=float)/32768; w.close()
print(f"durée {len(a)/sr:.2f} s")
for t0 in range(0, int(len(a)/sr)):
    seg=a[t0*sr:(t0+1)*sr]; f0=[]
    for i in range(0,len(seg)-1024,512):
        fr=seg[i:i+1024]
        if np.sqrt((fr**2).mean())<0.02: continue
        fr=fr-fr.mean(); ac=np.correlate(fr,fr,'full')[1023:]; ac/=ac[0]+1e-9; lo,hi=int(sr/400),int(sr/50); k=np.argmax(ac[lo:hi])+lo
        if ac[k]>0.5: f0.append(sr/k)
    z=(seg==0).mean()
    print(f"  {t0:2d}s  F0 {np.median(f0) if f0 else 0:4.0f} Hz  zéros {z:4.0%}")
PY
