#!/usr/bin/env python3
"""Répare une piste WAV 16 kHz enregistrée 2x trop vite par l'ancien tap (bug corrigé en 1.1.1) :
chaque bloc audio est ralenti de moitié et absorbe le silence de recalage (zéros exacts >= 20 ms) qui le suit.
usage : repair-2x.py <source.wav> <destination.wav> [facteur=2]"""
import sys, wave, array, numpy as np
src, dst = sys.argv[1], sys.argv[2]; k = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
w = wave.open(src); sr = w.getframerate(); a = np.array(array.array('h', w.readframes(w.getnframes())), dtype=np.int16); w.close()
MIN = int(0.02 * sr); nz = a != 0
edges = np.flatnonzero(np.diff(nz.astype(np.int8))) + 1; bounds = [0] + edges.tolist() + [len(a)]
runs = []
for s, e in zip(bounds[:-1], bounds[1:]):
    pad = (not nz[s]) and (e - s) >= MIN
    if runs and runs[-1][0] == pad: runs[-1] = (pad, runs[-1][1], e)
    else: runs.append((pad, s, e))
out = []; debt = 0
for pad, s, e in runs:
    seg = a[s:e]
    if not pad:
        x = seg.astype(float); idx = np.arange(0, len(x) - 1, 1 / k); y = np.interp(idx, np.arange(len(x)), x)
        out.append(y.astype(np.int16)); debt += len(y) - len(x)
    else:
        keep = max(0, len(seg) - debt); debt = max(0, debt - len(seg)); out.append(np.zeros(keep, dtype=np.int16))
y = np.concatenate(out)
o = wave.open(dst, "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(sr); o.writeframes(y.tobytes()); o.close()
print(f"{len(a)/sr:.1f} s -> {len(y)/sr:.1f} s, dette finale {debt/sr:.1f} s")
