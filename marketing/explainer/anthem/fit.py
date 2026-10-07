#!/usr/bin/env python3
"""Fit a generated take to the films' timing contract: 40.000 s, HIT at 36.500 s, silent by 39.900 s.

A music model has no clock, so the take's own big accent is found and slid onto 36.500 s, the result is
trimmed to 40.000 s, our hit sound (stamp + cash-register ka-ching + sub boom + sword shing, the same
instruments as marketing/music/anthem.py) is layered on the hit so the cut always lands, the bed is
faded under the end card, and the whole is mastered to -1 dBFS peak at 48 kHz stereo.

    python3 marketing/explainer/anthem/fit.py raw/A-1.wav [--hit-window 30 44] [--no-sfx]

Writes <name>-fit.wav + .mp3 beside the input and prints the measurements (where the accent was found,
how far it was moved, peak, tail). Pick by ear; the measurements only confirm the contract.
"""
import argparse
import json
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np
from scipy import signal

SR = 48_000
DUR, HIT, SILENT_BY = 40.0, 36.5, 39.9
rng = np.random.default_rng(1616)


def read_wav(path: Path) -> np.ndarray:
    """Any sample rate / width / channels -> float32 stereo at 48 kHz, via ffmpeg."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).T.astype(float)


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = (np.clip(x.T, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


def onset_strength(mono: np.ndarray, win=0.02):
    """Positive jump in band-limited energy (dB) per 20 ms hop; a crude but robust accent detector."""
    n = int(win * SR)
    nb = len(mono) // n
    frames = mono[: nb * n].reshape(nb, n)
    low = signal.sosfilt(signal.butter(2, [40, 300], "bandpass", fs=SR, output="sos"), mono)[: nb * n].reshape(nb, n)
    db = 20 * np.log10(np.sqrt((frames ** 2).mean(1)) + 1e-7)
    dbl = 20 * np.log10(np.sqrt((low ** 2).mean(1)) + 1e-7)
    jump = np.maximum(np.diff(db, prepend=db[0]), 0) + 0.7 * np.maximum(np.diff(dbl, prepend=dbl[0]), 0)
    # weight by how quiet the 150 ms before was (a hit after a gap is what the cut wants)
    pre = np.array([db[max(0, i - 8): i].mean() if i else db[0] for i in range(nb)])
    score = jump * (1 + np.clip((db - pre) / 20, 0, 1.5))
    return np.arange(nb) * win, score, db


# --- the hit sound, from anthem.py (same instruments, so the two films share one "stamp") ------------
def t_(dur): return np.arange(int(dur * SR)) / SR
def bp(x, lo, hi, order=2): return signal.sosfilt(signal.butter(order, [lo, hi], "bandpass", fs=SR, output="sos"), x)
def hp(x, f, order=2): return signal.sosfilt(signal.butter(order, f, "highpass", fs=SR, output="sos"), x)


def boom():
    t = t_(2.6); f = 32 + 60 * np.exp(-t * 9)
    return np.tanh(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 1.7) * 2.2)


def stamp():
    t = t_(0.25)
    knock = np.sin(2 * np.pi * (180 + 300 * np.exp(-t * 60)) * t) * np.exp(-t * 35)
    crack = bp(rng.standard_normal(len(t)), 1500, 7000) * np.exp(-t * 70)
    return np.tanh((knock + crack * 0.8) * 1.5) * 0.8


def ching():
    t = t_(2.2)
    partials = [(2960, 1.0, 2.6), (3520, 0.55, 3.2), (4435, 0.45, 3.8), (5920, 0.3, 4.8), (7040, 0.15, 6)]
    bell = sum(a * np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) * np.exp(-t * d) for f, a, d in partials)
    ka = bp(rng.standard_normal(len(t)), 2000, 9000) * np.exp(-t * 120) * 0.6
    bell = np.concatenate([np.zeros(int(0.045 * SR)), bell])[: len(t)]
    return (bell * 0.35 + ka) * np.minimum(t / 0.001, 1)


def sword():
    pre = 0.16; t = t_(pre + 1.4); n = rng.standard_normal(len(t))
    scrape = np.zeros_like(t); k = int(pre * SR); blk = 256
    for b in range(0, k, blk):
        f = 2500 * (9000 / 2500) ** (b / k)
        seg = bp(n[b: b + blk + 64], f * 0.8, min(f * 1.4, 20000))[:blk]
        scrape[b: b + len(seg)] = seg * (b / k) ** 1.5
    tr = np.clip(t - pre, 0, None)
    ring = sum(a * np.sin(2 * np.pi * f * tr * (1 + 0.0015 * np.sin(2 * np.pi * 7 * tr))) * np.exp(-tr * d)
               for f, a, d in [(5920, 1.0, 3.0), (7459, 0.7, 4.0), (8870, 0.5, 5.0), (11840, 0.35, 6.5), (3729, 0.3, 2.5)])
    ring *= (t >= pre) * np.minimum(tr / 0.0015, 1)
    hiss = hp(n, 6000) * np.exp(-tr * 18) * (t >= pre) * 0.5
    return scrape * 0.9 + ring * 0.32 + hiss, pre


def place(bus, x, at, gain=1.0, pan=0.0):
    i = int(round(at * SR)); x = x[: bus.shape[1] - i] * gain
    bus[0, i: i + len(x)] += x * np.sqrt(0.5 * (1 - pan)); bus[1, i: i + len(x)] += x * np.sqrt(0.5 * (1 + pan))


def main() -> None:
    ap = argparse.ArgumentParser()
    # The take is generated longer than the film, so by default the accent is searched from 36.5 s on:
    # the front is then TRIMMED, never padded with silence.
    ap.add_argument("take"); ap.add_argument("--hit-window", nargs=2, type=float, default=[HIT, 45.5])
    ap.add_argument("--no-sfx", action="store_true"); ap.add_argument("--hit-at", type=float, help="force the take's accent time")
    a = ap.parse_args()
    src = Path(a.take); x = read_wav(src); mono = x.mean(0)
    t, score, db = onset_strength(mono)
    lo, hi = a.hit_window
    m = (t >= lo) & (t <= hi)
    order = np.argsort(score[m])[::-1]
    cands = []
    for i in order:
        ti = float(t[m][i])
        if all(abs(ti - c) > 1.0 for c, _ in cands):
            cands.append((ti, round(float(score[m][i]), 1)))
        if len(cands) == 5:
            break
    print("accent candidates (t, score):", cands, file=sys.stderr)
    acc = a.hit_at if a.hit_at is not None else cands[0][0]
    shift = HIT - acc  # seconds to move the take by (positive = pad the front)
    N = int(DUR * SR)
    out = np.zeros((2, N))
    s0 = int(round(-shift * SR))  # first source sample that lands at t=0
    if s0 >= 0:
        seg = x[:, s0: s0 + N]; out[:, : seg.shape[1]] = seg
    else:
        seg = x[:, : N + s0]; out[:, -s0: -s0 + seg.shape[1]] = seg
        # fade the padded front in so the film does not start with a click
        out[:, : int(0.3 * SR)] *= np.linspace(0, 1, int(0.3 * SR))
    tt = np.arange(N) / SR
    # the bed under the end card: duck it a little after the hit and take it out by 39.9
    env = np.interp(tt, [0, HIT, HIT + 0.05, HIT + 2.6, SILENT_BY - 0.25, SILENT_BY, DUR], [1, 1, 0.9, 0.75, 0.35, 0, 0])
    out *= env
    if not a.no_sfx:
        sfx = np.zeros((2, N))
        place(sfx, boom(), HIT, 1.1); place(sfx, stamp(), HIT, 0.9); place(sfx, ching(), HIT + 0.02, 0.7, pan=0.15)
        blade, pre = sword(); place(sfx, blade, HIT - pre, 0.8, pan=-0.25)
        out += sfx * 0.8
    # master: gentle glue, soft clip, -1 dBFS
    level = signal.sosfiltfilt(signal.butter(1, 8, fs=SR, output="sos"), np.abs(out).max(0))
    out *= 1 / (1 + 1.2 * np.clip(level - 0.5, 0, None))
    out = np.tanh(out * 1.05)
    out *= 10 ** (-1 / 20) / (np.abs(out).max() + 1e-9)
    out[:, int(SILENT_BY * SR):] = 0
    dst = src.with_name(src.stem + "-fit.wav"); write_wav(dst, out)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(dst), "-codec:a", "libmp3lame", "-b:a", "320k", str(dst.with_suffix(".mp3"))], check=True)
    # measure the result the same way the brief asks
    t2, score2, db2 = onset_strength(out.mean(0))
    near = (t2 > 35.5) & (t2 < 37.5); got = float(t2[near][np.argmax(score2[near])])
    blocks = [round(float(db2[(t2 >= b) & (t2 < b + 4)].mean()), 1) for b in range(0, 40, 4)]
    rep = {"take": src.name, "accentFoundAt": round(acc, 3), "shiftSeconds": round(shift, 3), "hitMeasuredAt": got,
           "peak_dBFS": round(float(20 * np.log10(np.abs(out).max())), 2), "rms_dB_per_4s": blocks,
           "sourceSeconds": round(x.shape[1] / SR, 3), "out": dst.name}
    print(json.dumps(rep))
    Path(dst.with_suffix(".json")).write_text(json.dumps(rep, indent=1))


if __name__ == "__main__":
    main()
