#!/usr/bin/env python3
"""Film A's score: the launch cue (marketing/music/anthem.py) grown to 40 s and cut to film A's picture.

Same instruments as the launch video, so film A, which ends on the launch cut's push, blink and hit, ends on
the launch cue's hit too: phonk drums, the 808 and cowbell riff in F# Phrygian, the alarm pad, data blips, and
the braam + boom + stamp + ka-ching + sword on the cut. The instruments are taken from anthem.py itself (its
definitions are executed, its 10 s arrangement is not), so the two cues cannot drift apart.

Tempo: 22 bars to the hit, so 36.500 s lands on a downbeat (144.66 BPM). Picture events (film A after the
pacing warp, plan.plan_time) are scored where they happen, on or off the grid:

     0.0 - 1.7   bar 0     alarm pad swells, blips, drums muffled behind it        (the frozen note)
     1.7 - 8.3   bars 1-4  groove: kick, claps, hats, 808, cowbell riff             (lock IMD, borrow)
                           3.80 coin lands (clink), 4.50 flip (small ching), 4.80 print-out (swoosh)
     8.3 - 9.9   bar 5     fill, then the drums drop out                             (to the oracle)
     9.9 - 16.6  bars 6-9  "the panel": no kick, many blip voices in different subdivisions converging to one
                           12.30 collapse (falling blips), 13.50 flourish (swish), 15.40 drop (thud),
                           15.8-17.0 the strip types (a tick per glyph)
    16.6 - 21.6  bars10-12 groove back, riser into the stamp, a gap                 (reassembly, to the seal)
    22.20        STAMP     boom + stamp + ka-ching, off the grid, exactly on the slam
    21.6 - 26.5  bars13-15 the full groove, open hats                               (redemption)
    26.5 - 31.5  bars16-18 darker: riff low-passed, 808 slides down                 (liquidation)
                           29.70 note slides below the line (falling tone), 31.01 pulled off (whoosh + drop)
    31.5 - 36.5  bars19-21 groove, then the launch cue's build over two bars: hat rolls, cowbell stutter,
                           riser, reversed cymbal, a gap; a tick on the blink (35.45 close, 35.57 shut)
    36.500       HIT       braam + boom + stamp + ka-ching + sword, as in the launch cue
    36.5 - 40.0  tail      groove low-passed under the end card, silent by 39.9

    python3 marketing/explainer/anthem/score_a.py   -> marketing/explainer/anthem/film-a-score.wav (+ .mp3)
"""
import re
import subprocess
import wave
from pathlib import Path

import numpy as np
from scipy import signal

HERE = Path(__file__).parent
SRC = (HERE / "../../music/anthem.py").resolve().read_text()

# --- the launch cue's instruments, executed from its own source with this cue's clock
prefix = SRC[: SRC.index("# ------------------------------------------------------------------------------ arrangement")]
prefix = re.sub(r"^DUR = .*$", "DUR = 40.0", prefix, flags=re.M)
prefix = re.sub(r"^BEAT = .*$", "BEAT = 36.5 / 88  # 22 bars to the hit", prefix, flags=re.M)
prefix = re.sub(r"^HIT = .*$", "HIT = 36.5", prefix, flags=re.M)
ns = {"__name__": "anthem_instruments"}
exec(compile(prefix, "anthem.py(instruments)", "exec"), ns)
g = ns  # instruments and helpers: kick, eight08, clap, hat, cowbell, blip, braam, boom, stamp, ching, sword,
#         riser, reverse_cymbal, pad, reverb, Bus, note, bp, hp, lp, sweep_lp, t_, SR, N, BEAT, STEP, BAR, HIT
SR, N, BEAT, STEP, BAR, HIT, DUR = g["SR"], g["N"], g["BEAT"], g["STEP"], g["BAR"], g["HIT"], g["DUR"]
Bus, note, rng = g["Bus"], g["note"], g["rng"]
kick, eight08, clap, hat, cowbell, blip = g["kick"], g["eight08"], g["clap"], g["hat"], g["cowbell"], g["blip"]
t_, bp, hp, lp, sweep_lp = g["t_"], g["bp"], g["hp"], g["lp"], g["sweep_lp"]

drums, bass, bells, fx, pads, panel = Bus(), Bus(), Bus(), Bus(), Bus(), Bus()
KICKS = [0, 6, 10]
RIFF = [(0, "F#", 5), (3, "F#", 5), (6, "A", 5), (8, "G", 5), (10, "F#", 5), (11, "E", 5), (12, "C#", 5), (14, "D", 5)]
BASS = [(0, "F#", 1, 0.55, None), (6, "F#", 1, 0.35, None), (10, "A", 1, 0.5, "G")]
DARK_BASS = [(0, "F#", 1, 0.55, None), (6, "E", 1, 0.35, None), (10, "D", 1, 0.6, "C#")]
bs = lambda b: b * BAR


def groove(b, riff=True, bassline=BASS, open_hats=False, fill=False, riff_bus=None, gain=1.0):
    t0 = bs(b)
    for s in KICKS:
        drums.add(kick(), t0 + s * STEP, 0.95 * gain)
    for s in (4, 12):
        drums.add(clap(), t0 + s * STEP, 0.75 * gain)
    for s in range(16):
        drums.add(hat(open_=(s == 14 or (open_hats and s in (6, 14)))), t0 + s * STEP, (0.35 if s % 2 else 0.5) * gain, pan=0.35)
        if fill and s in (7, 15):
            drums.add(hat(), t0 + (s + 0.5) * STEP, 0.3 * gain, pan=0.35)
    for s, n, o, d, gl in bassline:
        bass.add(eight08(note(n, o), d, note(gl, o) if gl else None), t0 + s * STEP, 0.9 * gain)
    if riff:
        for s, n, o in RIFF:
            (riff_bus or bells).add(cowbell(note(n, o)), t0 + s * STEP, 0.55 * gain, pan=-0.2)


def swoosh(dur=0.45, up=True):
    t = t_(dur)
    n = hp(rng.standard_normal(len(t)), 300)
    f0, f1 = (800, 9000) if up else (9000, 700)
    x = sweep_lp(n, f0, f1) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 2
    return x * 0.6


def clink():
    t = t_(0.5)
    x = sum(a * np.sin(2 * np.pi * f * t) * np.exp(-t * d) for f, a, d in [(2637, 1, 9), (3951, .6, 12), (5274, .35, 16)])
    return x * np.minimum(t / 0.001, 1) * 0.5


def thud():
    t = t_(0.4)
    return np.tanh(np.sin(2 * np.pi * (60 + 90 * np.exp(-t * 30)) * t) * np.exp(-t * 9) * 2.0) * 0.9


def fall(dur=0.9, f0=1200, f1=180):
    t = t_(dur)
    f = f0 * (f1 / f0) ** (t / dur)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.2) * 0.35


# ---- bar 0: the command centre wakes (the frozen note)
pads.add(g["pad"](BAR + 0.3, note("F#", 2)), 0.0)
for i in range(int(BAR / (STEP / 2))):
    if rng.random() < 0.55:
        fx.add(blip(rng.choice([1760, 2093, 2637, 3136, 3520, 4186])), i * STEP / 2, 0.12, rng.uniform(-0.8, 0.8))
muffled = Bus()
for s in KICKS:
    muffled.add(kick(0.8), s * STEP, 0.9)
muffled.add(clap(), 12 * STEP, 0.6)

# ---- bars 1-4: lock IMD, borrow dollars
for b in range(1, 5):
    groove(b, fill=(b == 4))
fx.add(swoosh(0.35), 3.80 - 0.30, 0.5, pan=-0.3); fx.add(clink(), 3.80, 0.7, pan=-0.1)       # coin lands
fx.add(g["ching"](), 4.50, 0.35, pan=0.2)                                                         # the flip
fx.add(swoosh(0.6), 4.80, 0.45, pan=0.25)                                                         # print-out
# ---- bar 5: fill, then out
groove(5, fill=True)
fx.add(g["reverse_cymbal"](0.5), bs(6) - 0.5, 0.6)

# ---- bars 6-9: the panel. Voices tick in 3, 4, 5, 6, 7 and 9 per bar; each starts on its own pitch and moves
# to F# as the bars go, so by bar 9 they agree on one note.
voices = [(3, 1760), (4, 2093), (5, 2637), (6, 3136), (7, 3520), (9, 4186)]
target = note("F#", 6)
for b in range(6, 10):
    agree = (b - 6) / 3
    for k, (per, f) in enumerate(voices):
        if b == 6 and k > 2:
            continue                                  # the panel fills in: three voices, then all six
        for i in range(per):
            ff = f * (target / f) ** agree
            panel.add(blip(ff, 0.05), bs(b) + i * BAR / per, 0.16, pan=-0.8 + 1.6 * k / 5)
    for s in (4, 12):
        drums.add(clap(), bs(b) + s * STEP, 0.45)
    for s in range(0, 16, 2):
        drums.add(hat(), bs(b) + s * STEP, 0.28, pan=0.35)
    bass.add(eight08(note("F#", 1), BAR * 0.9), bs(b), 0.45)   # one held 808 per bar under the panel
for i in range(6):                                                # the collapse: falling blips
    fx.add(blip(3520 * 0.82 ** i, 0.05), 12.30 + i * 0.06, 0.2, pan=0.3 - 0.12 * i)
fx.add(swoosh(0.5, up=False), 13.50, 0.4)                       # the flourish
fx.add(thud(), 15.40, 0.8)                                       # the medallion drops onto the strip
for i in range(12):                                              # the strip types, a tick per glyph
    fx.add(blip(2637, 0.025), 15.80 + i * 0.1, 0.22, pan=-0.4 + 0.07 * i)

# ---- bars 10-12: groove back, a riser into the stamp, then a gap
for b in (10, 11):
    groove(b)
groove(12, fill=True)
fx.add(g["riser"](bs(13) - bs(12) + (22.2 - bs(13))), bs(12), 0.7)

# ---- the stamp, exactly on the slam (off the grid)
STAMP = 22.20
fx.add(g["boom"](), STAMP, 1.0); fx.add(g["stamp"](), STAMP, 1.0); fx.add(g["ching"](), STAMP + 0.02, 0.6, pan=0.15)
drums.add(clap(), STAMP, 0.7)

# ---- bars 13-15: redemption, the full groove
for b in (13, 14, 15):
    groove(b, open_hats=True, fill=(b == 15))

# ---- bars 16-18: liquidation, darker
dark_bells = Bus()
for b in (16, 17, 18):
    groove(b, bassline=DARK_BASS, riff_bus=dark_bells)
fx.add(fall(1.1, 900, 140), 29.70, 0.8)                                   # slides below the line
fx.add(swoosh(0.5), 31.01 - 0.25, 0.7, pan=0.4); fx.add(g["boom"](), 31.01, 0.5)   # pulled off

# ---- bars 19-21: groove, then the launch cue's build stretched over two bars
groove(19)
for b in (20, 21):
    t0 = bs(b)
    for s in ((0, 4, 8, 12) if b == 20 else (0, 4, 6, 8, 10, 12, 13, 14)):
        drums.add(kick(1.05), t0 + s * STEP, 0.95)
    drums.add(clap(), t0 + 4 * STEP, 0.75)
    for i in range(32 if b == 21 else 16):
        if b == 21 and i >= 30:
            continue
        step = STEP / 2 if b == 21 else STEP
        drums.add(hat(), t0 + i * step, 0.22 + (0.35 * i / 32 if b == 21 else 0.1), pan=0.35)
    for s, n, o in RIFF[:5]:
        bells.add(cowbell(note(n, o)), t0 + s * STEP, 0.55, pan=-0.2)
bass.add(eight08(note("F#", 1), BAR * 1.9, note("F#", 2)), bs(20), 0.7)
for i in range(8):
    bells.add(cowbell(note("F#", 5) * 2 ** (i / 12)), bs(21) + 11 * STEP + i * STEP / 2, 0.35 + 0.04 * i, pan=0.2)
fx.add(g["riser"](2 * BAR - 0.02), bs(20), 0.8)
fx.add(g["reverse_cymbal"](0.6), HIT - 0.6, 0.9)
fx.add(blip(3136, 0.04), 35.45, 0.18); fx.add(blip(2093, 0.06), 35.57, 0.22)   # the blink

# ---- the hit, as in the launch cue
fx.add(g["boom"](), HIT, 1.4)
pads.add(g["braam"](3.4, note("F#", 1)), HIT, 1.3)
fx.add(g["stamp"](), HIT, 0.9)
fx.add(g["ching"](), HIT + 0.02, 0.75, pan=0.15)
blade, pre = g["sword"]()
fx.add(blade, HIT - pre, 0.9, pan=-0.25)
bells.add(cowbell(note("F#", 6)), HIT, 0.5)
drums.add(clap(), HIT, 0.8)

# ---- tail under the end card
tail_d, tail_b, tail_c = Bus(), Bus(), Bus()
for b in (22, 23):
    t0 = bs(b)
    for s in KICKS:
        tail_d.add(kick(), t0 + s * STEP, 0.95)
    for s in (4, 12):
        tail_d.add(clap(), t0 + s * STEP, 0.75)
    for s, n, o, d, gl in [(0, "F#", 1, 0.55, None), (6, "F#", 1, 0.35, None), (10, "F#", 1, 0.9, None)]:
        tail_b.add(eight08(note(n, o), d, None), t0 + s * STEP, 0.9)
    for s, n, o in RIFF:
        tail_c.add(cowbell(note(n, o)), t0 + s * STEP, 0.55, pan=-0.2)

# ------------------------------------------------------------------------------ mix
st = lambda bus: bus.stereo()
tt = np.arange(N) / SR
env_at = lambda kv: np.interp(tt, *zip(*kv))
def gap(at, length):
    x = 1 - ((tt > at - length) & (tt < at)).astype(float)
    return signal.sosfiltfilt(signal.butter(1, 200, fs=SR, output="sos"), x)
gaps = gap(HIT, STEP * 2.5) * gap(STAMP, STEP * 2)

mix = np.zeros((2, N))
mix += st(drums) * 0.6 * gaps
mix += st(bass) * 0.58 * gaps
mix += np.stack([g["reverb"](c, 1.2, 0.18) for c in st(bells)]) * 0.7 * gaps
mix += np.stack([g["reverb"](sweep_lp(c, 700, 380), 1.6, 0.3) for c in st(dark_bells)]) * 0.75 * gaps   # liquidation
mix += np.stack([g["reverb"](c, 1.8, 0.35) for c in st(panel)]) * 0.75
mix += np.stack([g["reverb"](c, 2.2, 0.35) for c in st(pads)]) * 0.9
mix += np.stack([g["reverb"](c, 1.6, 0.22) for c in st(fx)]) * 0.85
mix += np.stack([hp(lp(c, 380), 50) for c in st(muffled)]) * 0.6
tail = st(tail_d) * 0.55 + st(tail_b) * 0.45 + st(tail_c) * 0.4
tail = np.stack([sweep_lp(c, 900, 260) for c in tail])
mix += tail * env_at([(0, 0), (HIT + 0.35, 0), (HIT + 0.9, 0.9), (38.6, 0.6), (39.7, 0.0), (DUR, 0)])

kick_env = np.abs(np.stack([lp(c, 120) for c in st(drums)])).sum(0)
kick_env = signal.sosfiltfilt(signal.butter(1, 12, fs=SR, output="sos"), kick_env)
mix *= 1 - 0.25 * kick_env / (kick_env.max() + 1e-9)
level = signal.sosfiltfilt(signal.butter(1, 8, fs=SR, output="sos"), np.abs(mix).max(0))
mix *= 1 / (1 + 1.6 * np.clip(level - 0.35, 0, None))
mix = np.tanh(mix * 1.15)
mix *= env_at([(0, 1), (39.6, 1), (39.88, 0), (DUR, 0)])
mix *= 10 ** (-1 / 20) / np.abs(mix).max()

out = HERE / "film-a-score.wav"
pcm = (np.clip(mix.T, -1, 1) * 32767).astype("<i2")
with wave.open(str(out), "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(out), "-codec:a", "libmp3lame", "-b:a", "320k", str(out.with_suffix(".mp3"))], check=True)
print(f"wrote {out}  {N / SR:.3f} s  {60 / BEAT:.2f} BPM  peak -1.0 dBFS  rms {20 * np.log10(np.sqrt(np.mean(mix ** 2))):.1f} dBFS")
