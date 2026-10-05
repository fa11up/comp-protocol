#!/usr/bin/env python3
"""imdUSD launch cue: "NERV alert at the treasury".

A 10.0 s cue for the launch video, synthesized from scratch (numpy + scipy, no samples).
Phonk-style drums, distorted 808 and cowbell riff in F# Phrygian, an Evangelion-style alarm pad
and brass "braam", command-center data blips, and money for the hit: a stamp and a ka-ching.

    0.000 – 1.625  bar 1   alarm pad swells, data blips, drums muffled behind it
    1.625 – 4.875  bars 2-3  full groove: 808, cowbell riff, claps, hats
    4.875 – 6.500  bar 4   build: hat rolls, cowbell stutter, riser, a gap and a reversed cymbal
    6.500          HIT     braam + boom + stamp + ka-ching, exactly on the video's cut
    6.500 – 10.00  tail    groove continues low-passed under the end card, fades to silence

Tempo is 960/6.5 = 147.69 BPM so the hit lands on a downbeat (16 beats in).
Run: python3 marketing/music/anthem.py [outdir]   -> imdusd-anthem.wav (48 kHz, 16-bit, stereo)
"""
import sys
import wave
from pathlib import Path

import numpy as np
from scipy import signal

SR = 48_000
DUR = 10.0
N = int(SR * DUR)
BEAT = 6.5 / 16  # seconds
STEP = BEAT / 4  # sixteenth
BAR = BEAT * 4
HIT = 6.5
rng = np.random.default_rng(1616)


def t_(dur):
    return np.arange(int(dur * SR)) / SR


def hz(semi_from_a4):
    return 440.0 * 2 ** (semi_from_a4 / 12)


# F# Phrygian, as semitones from A4: F#=-3, G=-2, A=0, B=2, C#=4, D=5, E=7
def note(name, octave):
    base = {"F#": -3, "G": -2, "A": 0, "B": 2, "C#": 4, "D": 5, "E": 7}[name]
    return hz(base + 12 * (octave - 4))


class Bus:
    def __init__(self):
        self.l = np.zeros(N + SR)
        self.r = np.zeros(N + SR)

    def add(self, x, at, gain=1.0, pan=0.0):
        i = int(round(at * SR))
        if i >= len(self.l):
            return
        x = x[: len(self.l) - i] * gain
        self.l[i : i + len(x)] += x * np.sqrt(0.5 * (1 - pan))
        self.r[i : i + len(x)] += x * np.sqrt(0.5 * (1 + pan))

    def stereo(self):
        return np.stack([self.l[:N], self.r[:N]])


def bp(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, hi], "bandpass", fs=SR, output="sos"), x)


def hp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, "highpass", fs=SR, output="sos"), x)


def lp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, "lowpass", fs=SR, output="sos"), x)


def sweep_lp(x, f0, f1, block=256):
    """Low-pass whose cutoff glides exponentially from f0 to f1 across x (block-wise, state kept)."""
    out = np.zeros_like(x)
    zi = None
    nb = int(np.ceil(len(x) / block))
    for b in range(nb):
        f = f0 * (f1 / f0) ** (b / max(nb - 1, 1))
        sos = signal.butter(2, min(f, SR * 0.45), "lowpass", fs=SR, output="sos")
        if zi is None:
            zi = signal.sosfilt_zi(sos) * x[0]
        seg = x[b * block : (b + 1) * block]
        out[b * block : b * block + len(seg)], zi = signal.sosfilt(sos, seg, zi=zi)
    return out


def saw(f, t, detune=0.0):
    ph = (f * (1 + detune)) * t
    return 2 * (ph - np.floor(ph + 0.5))


# ------------------------------------------------------------------------------ instruments
def kick(punch=1.0):
    t = t_(0.5)
    f = 45 + 110 * np.exp(-t * 28)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7)
    click = hp(rng.standard_normal(len(t)), 3000) * np.exp(-t * 400) * 0.4
    return np.tanh((body + click) * 1.6 * punch)


def eight08(f, dur, glide_to=None):
    t = t_(dur)
    freq = np.full_like(t, f)
    if glide_to:
        k = np.clip((t - dur * 0.55) / (dur * 0.3), 0, 1)
        freq = f * (glide_to / f) ** k
    freq = freq * (1 + 1.2 * np.exp(-t * 60))  # pitch-drop punch on the attack
    ph = 2 * np.pi * np.cumsum(freq) / SR
    x = np.sin(ph) + 0.2 * np.sin(2 * ph)  # a touch of 2nd harmonic so it still reads on phone speakers
    env = np.minimum(t / 0.002, 1) * np.exp(-t * 1.3)
    hard = np.tanh(x * env * 4.2)  # driven, but rounder than full saturation
    return lp(hard, 2800) * 0.85  # keep the growl, lose the fizz


def clap():
    t = t_(0.35)
    n = rng.standard_normal(len(t))
    env = np.zeros_like(t)
    for d in (0, 0.009, 0.018):
        env += (t >= d) * np.exp(-np.clip(t - d, 0, None) * 180) * 0.7
    env += (t >= 0.026) * np.exp(-np.clip(t - 0.026, 0, None) * 16)
    return bp(n, 900, 4500) * env * 1.4


def hat(open_=False):
    t = t_(0.25 if open_ else 0.06)
    n = hp(rng.standard_normal(len(t)), 7500, 4)
    return n * np.exp(-t * (14 if open_ else 90)) * 0.5


def cowbell(f):
    """The 808 cowbell: two square waves a ratio of ~1.48 apart, band-passed, pitched to `f`."""
    t = t_(0.32)
    x = signal.square(2 * np.pi * f * t) + signal.square(2 * np.pi * f * 1.48 * t)
    x = bp(x, f * 0.9, min(f * 6, 16000))
    env = np.minimum(t / 0.001, 1) * (0.6 * np.exp(-t * 40) + 0.4 * np.exp(-t * 9))
    return np.tanh(x * env * 1.3) * 0.5


def blip(f, dur=0.035):
    t = t_(dur)
    return np.sin(2 * np.pi * f * t) * np.exp(-t * 60) * np.minimum(t / 0.002, 1)


def braam(dur, f_root):
    """Brass-like wall: stacked detuned saws with a b2 for Eva tension, filter-swept open then closed."""
    t = t_(dur)
    chord = [f_root, f_root * 2, f_root * 3, f_root * 4 * 2 ** (3 / 12), f_root * 4]  # F#, F#, C#, A, F#
    x = sum(saw(f, t, d) for f in chord for d in (-0.003, 0.0, 0.003))
    tension = f_root * 4 * 2 ** (1 / 12)  # the b2, gone within a quarter second
    x = x + sum(saw(tension, t, d) for d in (-0.006, 0.006)) * np.exp(-t * 9)
    env = np.minimum(t / 0.012, 1) * np.exp(-t * 1.5)  # settles by ~8.5 s instead of droning on
    x = x * env
    # bright at the hit, closing as it decays
    out = np.zeros_like(x)
    blk = 512
    zi = None
    for b in range(int(np.ceil(len(x) / blk))):
        tt = b * blk / SR
        fc = 300 + 4200 * np.exp(-tt * 2.2)
        sos = signal.butter(2, fc, "lowpass", fs=SR, output="sos")
        if zi is None:
            zi = signal.sosfilt_zi(sos) * 0
        seg = x[b * blk : (b + 1) * blk]
        out[b * blk : b * blk + len(seg)], zi = signal.sosfilt(sos, seg, zi=zi)
    return hp(np.tanh(out * 0.55), 55)


def boom():
    t = t_(2.6)
    f = 32 + 60 * np.exp(-t * 9)
    return np.tanh(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 1.7) * 2.2)


def stamp():
    t = t_(0.25)
    knock = np.sin(2 * np.pi * (180 + 300 * np.exp(-t * 60)) * t) * np.exp(-t * 35)
    crack = bp(rng.standard_normal(len(t)), 1500, 7000) * np.exp(-t * 70)
    return np.tanh((knock + crack * 0.8) * 1.5) * 0.8


def ching():
    """Cash-register bell: inharmonic metallic partials with a fast mechanical 'ka' in front."""
    t = t_(2.2)
    partials = [(2960, 1.0, 2.6), (3520, 0.55, 3.2), (4435, 0.45, 3.8), (5920, 0.3, 4.8), (7040, 0.15, 6)]
    bell = sum(a * np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) * np.exp(-t * d) for f, a, d in partials)
    ka = bp(rng.standard_normal(len(t)), 2000, 9000) * np.exp(-t * 120) * 0.6
    bell = np.concatenate([np.zeros(int(0.045 * SR)), bell])[: len(t)]  # "ka" ... "ching"
    return (bell * 0.35 + ka) * np.minimum(t / 0.001, 1)


def sword():
    """Katana draw: a metallic scrape rising for 0.16 s, then a ringing blade (bright partials tuned
    around F#, with shimmer) that decays over ~1.2 s. Returns (audio, offset): place it at HIT - offset."""
    pre = 0.16
    t = t_(pre + 1.4)
    n = rng.standard_normal(len(t))
    # scrape: band-passed noise whose band climbs as the blade leaves the scabbard
    scrape = np.zeros_like(t)
    k = int(pre * SR)
    blk = 256
    for b in range(0, k, blk):
        f = 2500 * (9000 / 2500) ** (b / k)
        seg = bp(n[b : b + blk + 64], f * 0.8, min(f * 1.4, 20000))[:blk]
        scrape[b : b + len(seg)] = seg * (b / k) ** 1.5
    # ring: inharmonic blade partials, slight vibrato, fast attack at the hit
    tr = np.clip(t - pre, 0, None)
    ring = sum(a * np.sin(2 * np.pi * f * tr * (1 + 0.0015 * np.sin(2 * np.pi * 7 * tr))) * np.exp(-tr * d)
               for f, a, d in [(5920, 1.0, 3.0), (7459, 0.7, 4.0), (8870, 0.5, 5.0), (11840, 0.35, 6.5), (3729, 0.3, 2.5)])
    ring *= (t >= pre) * np.minimum(tr / 0.0015, 1)
    hiss = hp(n, 6000) * np.exp(-tr * 18) * (t >= pre) * 0.5
    return scrape * 0.9 + ring * 0.32 + hiss, pre


def riser(dur):
    t = t_(dur)
    n = rng.standard_normal(len(t))
    noise = sweep_lp(hp(n, 400), 600, 14000) * (t / dur) ** 2
    tone = saw(1, t)  # placeholder phase reset below
    f = 110 * 2 ** (2 * t / dur)  # two octaves up
    tone = np.sin(2 * np.pi * np.cumsum(f) / SR) * (t / dur) ** 3 * 0.35
    return noise * 0.5 + tone


def reverse_cymbal(dur):
    t = t_(dur)
    x = hp(rng.standard_normal(len(t)), 5000) * np.exp(-t * 5)
    return x[::-1] * 0.6


def pad(dur, f_root):
    """Alarm pad: F#m with a b2 above, detuned saws through a slow wobbling low-pass."""
    t = t_(dur)
    chord = [f_root, f_root * 2 ** (3 / 12), f_root * 2 ** (7 / 12), f_root * 2 ** (13 / 12)]
    x = sum(saw(f, t, d) for f in chord for d in (-0.004, 0.004))
    x = sweep_lp(x, 250, 2400)
    swell = np.clip(t / dur, 0, 1) ** 1.5
    trem = 0.75 + 0.25 * np.sin(2 * np.pi * (1 / BEAT) * t)  # pulses with the beat, like a klaxon
    return hp(x, 160) * swell * trem * 0.16


def reverb(x, seconds=1.4, mix=0.25):
    t = t_(seconds)
    ir = rng.standard_normal(len(t)) * np.exp(-t * 4.5)
    ir = lp(ir, 6000)
    ir /= np.sqrt(np.sum(ir**2))
    wet = signal.fftconvolve(x, ir)[: len(x)]
    return x + wet * mix


# ------------------------------------------------------------------------------ arrangement
drums, bass, bells, fx, pads = Bus(), Bus(), Bus(), Bus(), Bus()

KICKS = [0, 6, 10]          # 16th steps within a bar, phonk bounce
RIFF = [  # (step, note, octave) cowbell riff, F# Phrygian
    (0, "F#", 5), (3, "F#", 5), (6, "A", 5), (8, "G", 5), (10, "F#", 5),
    (11, "E", 5), (12, "C#", 5), (14, "D", 5),
]
BASS = [(0, "F#", 1, 0.55, None), (6, "F#", 1, 0.35, None), (10, "A", 1, 0.5, "G")]


def bar_start(b):
    return b * BAR


# Bar 1: the command centre wakes up. Alarm pad, data blips, drums muffled (added low-passed later).
pads.add(pad(BAR + 0.3, note("F#", 2)), 0.0)
for i in range(int(BAR / (STEP / 2))):
    if rng.random() < 0.55:
        fx.add(blip(rng.choice([1760, 2093, 2637, 3136, 3520, 4186])), i * STEP / 2, 0.12, rng.uniform(-0.8, 0.8))

muffled = Bus()
for s in KICKS:
    muffled.add(kick(0.8), bar_start(0) + s * STEP, 0.9)
muffled.add(clap(), bar_start(0) + 12 * STEP, 0.6)

# Bars 2-3 (and the tail): the groove.
def groove(b, bus_d, bus_b, bus_c, fill=False):
    t0 = bar_start(b)
    for s in KICKS:
        bus_d.add(kick(), t0 + s * STEP, 0.95)
    for s in (4, 12):
        bus_d.add(clap(), t0 + s * STEP, 0.75)
    for s in range(16):
        bus_d.add(hat(open_=(s == 14)), t0 + s * STEP, 0.35 if s % 2 else 0.5, pan=0.35)
        if fill and s in (7, 15):
            bus_d.add(hat(), t0 + (s + 0.5) * STEP, 0.3, pan=0.35)
    for s, n, o, d, g in BASS:
        bus_b.add(eight08(note(n, o), d, note(g, o) if g else None), t0 + s * STEP, 0.9)
    for s, n, o in RIFF:
        bus_c.add(cowbell(note(n, o)), t0 + s * STEP, 0.55, pan=-0.2)


groove(1, drums, bass, bells)
groove(2, drums, bass, bells, fill=True)

# Bar 4: the build. Kicks thicken, hats roll to 32nds, the cowbell stutters, a riser climbs, then a gap.
t0 = bar_start(3)
for s in (0, 4, 6, 8, 10, 12, 13, 14):
    drums.add(kick(1.1), t0 + s * STEP, 0.95)
drums.add(clap(), t0 + 4 * STEP, 0.75)
for i in range(32):  # 32nd-note hat roll, rising in level
    if i < 30:
        drums.add(hat(), t0 + i * STEP / 2, 0.25 + 0.35 * i / 32, pan=0.35)
for s, n, o in RIFF[:5]:
    bells.add(cowbell(note(n, o)), t0 + s * STEP, 0.55, pan=-0.2)
for i in range(8):  # stutter: the riff's last note retriggered in 32nds, pitching up
    bells.add(cowbell(note("F#", 5) * 2 ** (i / 12)), t0 + 11 * STEP + i * STEP / 2, 0.35 + 0.04 * i, pan=0.2)
bass.add(eight08(note("F#", 1), BAR * 0.95, note("F#", 2)), t0, 0.7)  # 808 glides up an octave
fx.add(riser(BAR - 0.02), t0, 0.8)
fx.add(reverse_cymbal(0.6), HIT - 0.6, 0.9)
# the gap: everything but the reversed cymbal stops for the last eighth before the hit

# The hit.
fx.add(boom(), HIT, 1.4)
pads.add(braam(3.4, note("F#", 1)), HIT, 1.3)
fx.add(stamp(), HIT, 0.9)
fx.add(ching(), HIT + 0.02, 0.75, pan=0.15)
blade, pre = sword()
fx.add(blade, HIT - pre, 0.9, pan=-0.25)
bells.add(cowbell(note("F#", 6)), HIT, 0.5)
drums.add(clap(), HIT, 0.8)

# Tail: the groove keeps going under the end card, low-passed, and fades out.
tail_d, tail_b, tail_c = Bus(), Bus(), Bus()
groove(4, tail_d, tail_b, tail_c)
BASS[:] = [(0, "F#", 1, 0.55, None), (6, "F#", 1, 0.35, None), (10, "F#", 1, 0.9, None)]  # resolve home
groove(5, tail_d, tail_b, tail_c)

# ------------------------------------------------------------------------------ mix
def st(bus):
    return bus.stereo()


def env_at(times_vals):
    ts, vs = zip(*times_vals)
    return np.interp(np.arange(N) / SR, ts, vs)


gap = 1 - ((np.arange(N) / SR > HIT - STEP * 2.5) & (np.arange(N) / SR < HIT)).astype(float)
gap = signal.sosfiltfilt(signal.butter(1, 200, fs=SR, output="sos"), gap)  # de-click the gap edges

mix = np.zeros((2, N))
mix += st(drums) * 0.6 * gap
mix += st(bass) * 0.58 * gap
mix += np.stack([reverb(c, 1.2, 0.18) for c in st(bells)]) * 0.7 * gap
mix += np.stack([reverb(c, 2.2, 0.35) for c in st(pads)]) * 0.9
mix += np.stack([reverb(c, 1.6, 0.22) for c in st(fx)]) * 0.85

# bar 1's drums, muffled as if through a wall, opening up into bar 2
md = st(muffled)
mix += np.stack([hp(lp(c, 380), 50) for c in md]) * 0.6

# tail groove: low-passed and fading, so the end card has a pulse under it without competing
tail = st(tail_d) * 0.55 + st(tail_b) * 0.45 + st(tail_c) * 0.4
tail = np.stack([sweep_lp(c, 900, 260) for c in tail])
mix += tail * env_at([(0, 0), (HIT + 0.35, 0), (HIT + 0.9, 0.9), (8.6, 0.6), (9.75, 0.0), (DUR, 0)])

# sidechain: the kick ducks the pads and tail so the low end stays clean
kick_env = np.abs(np.stack([lp(c, 120) for c in st(drums)])).sum(0)
kick_env = signal.sosfiltfilt(signal.butter(1, 12, fs=SR, output="sos"), kick_env)
kick_env /= kick_env.max() + 1e-9
mix *= 1 - 0.25 * kick_env

# master: glue compression, soft clip, peak to -1 dBFS, silence before 10.0 s
level = signal.sosfiltfilt(signal.butter(1, 8, fs=SR, output="sos"), np.abs(mix).max(0))
gain = 1 / (1 + 1.6 * np.clip(level - 0.35, 0, None))
mix *= gain
mix = np.tanh(mix * 1.15)
fade = env_at([(0, 1), (9.7, 1), (9.95, 0), (DUR, 0)])
mix *= fade
mix *= 10 ** (-1 / 20) / np.abs(mix).max()

out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
out.mkdir(parents=True, exist_ok=True)
path = out / "imdusd-anthem.wav"
pcm = (np.clip(mix.T, -1, 1) * 32767).astype("<i2")
with wave.open(str(path), "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
rms = 20 * np.log10(np.sqrt(np.mean(mix**2)) + 1e-12)
print(f"wrote {path}  {N / SR:.3f} s  peak -1.0 dBFS  rms {rms:.1f} dBFS")
