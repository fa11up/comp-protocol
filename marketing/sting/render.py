#!/usr/bin/env python3
"""Original imdUSD eyecatches. Python stdlib synthesis; FFmpeg encodes MP3.

No samples, soundfonts, models, network, or third-party Python packages.
Run from any directory: python3 marketing/sting/render.py [output_directory]
"""
from array import array
import json
import math
from pathlib import Path
import random
import subprocess
import sys
import wave

SR = 48000
FRAMES = 10 * SR
TAU = math.tau
HIT = 6.5


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def release(t, gate, length):
    if t <= gate:
        return 1.0
    if t >= gate + length:
        return 0.0
    return math.cos((t - gate) / length * math.pi / 2) ** 2


class Studio:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.dry = [array('d', [0.0]) * FRAMES for _ in range(2)]
        self.send = [array('d', [0.0]) * FRAMES for _ in range(2)]
        self.events = []

    def place(self, sound, when, level, pan=0.0, room=0.16, kind='note'):
        start = round(when * SR)
        assert 0 <= start <= round(HIT * SR), 'No new attacks after end-card cut'
        self.events.append({'instrument': kind, 'seconds': round(when, 6)})
        left = math.cos((pan + 1) * math.pi / 4) * level
        right = math.sin((pan + 1) * math.pi / 4) * level
        dl, dr = self.dry
        sl, sr = self.send
        for i, v in enumerate(sound):
            at = start + i
            if at >= FRAMES:
                break
            l, r = v * left, v * right
            dl[at] += l
            dr[at] += r
            sl[at] += l * room
            sr[at] += r * room

    def piano(self, midi, gate, mellow=False, final=False):
        f = hz(midi)
        tail = 1.05 if final else 0.24
        phase = self.rng.random() * TAU
        out = array('d')
        for i in range(round((gate + tail) * SR)):
            t = i / SR
            # Tiny independent pitch drift and amplitude tremolo, not a voice/formant.
            p = TAU * f * t + 0.006 * math.sin(TAU * 0.71 * t + phase)
            idx = (0.85 if mellow else 1.12) * math.exp(-t / 0.21) + 0.10
            body = math.sin(p + idx * math.sin(2 * p))
            tine = 0.12 * math.sin(3 * p + 0.2) * math.exp(-t / 0.12)
            env = (1 - math.exp(-t / 0.004)) * (
                0.68 * math.exp(-t / 0.75) + 0.32 * math.exp(-t / 2.5))
            trem = 0.97 + 0.03 * math.sin(TAU * 3.1 * t + phase)
            out.append((body + tine) * env * trem * release(t, gate, tail))
        return out

    def bell(self, midi, gate, final=False):
        f = hz(midi)
        tail = 1.5 if final else 0.48
        out = array('d')
        for i in range(round((gate + tail) * SR)):
            t = i / SR
            p = TAU * f * t
            # A dominant tuned fundamental with quiet glassy inharmonic partials.
            v = (math.sin(p) * math.exp(-t / 0.85)
                 + 0.22 * math.sin(p * 2.756) * math.exp(-t / 0.19)
                 + 0.085 * math.sin(p * 4.07) * math.exp(-t / 0.11))
            out.append(v * (1 - math.exp(-t / 0.0025)) * release(t, gate, tail))
        return out

    def bass(self, midi, gate):
        out = array('d')
        f = hz(midi)
        for i in range(round((gate + 0.18) * SR)):
            t = i / SR
            p = TAU * f * t
            env = (1 - math.exp(-t / 0.009)) * math.exp(-t / 1.7)
            out.append((math.sin(p) + 0.16 * math.sin(2 * p)) * env
                       * release(t, gate, 0.18))
        return out

    def drum(self, kind):
        duration = {'kick': 0.26, 'snare': 0.17, 'hat': 0.075, 'stamp': 0.16}[kind]
        out = array('d')
        lp = prev = 0.0
        for i in range(round(duration * SR)):
            t = i / SR
            noise = self.rng.uniform(-1, 1)
            lp += 0.24 * (noise - lp)
            high = noise - lp
            if kind == 'kick':
                p = TAU * (54 * t + 85 * 0.018 * (1 - math.exp(-t / 0.018)))
                v = math.sin(p) * math.exp(-t / 0.065)
                v += 0.08 * lp * math.exp(-t / 0.007)
            elif kind == 'snare':
                v = (0.67 * lp + 0.19 * high) * math.exp(-t / 0.031)
                v += 0.30 * math.sin(TAU * 181 * t) * math.exp(-t / 0.023)
                v += 0.12 * math.sin(TAU * 337 * t) * math.exp(-t / 0.012)
            elif kind == 'hat':
                v = 0.43 * (high - prev * 0.4) * math.exp(-t / 0.013)
                prev = high
            else:
                # Original dry rubber/wood stamp: low knock + band-limited paper crack.
                p = TAU * (132 * t + 210 * 0.006 * (1 - math.exp(-t / 0.006)))
                v = 0.77 * math.sin(p) * math.exp(-t / 0.027)
                v += (0.74 * lp + 0.22 * high) * math.exp(-t / 0.010)
                v += 0.16 * math.sin(TAU * 1260 * t) * math.exp(-t / 0.006)
            attack = min(1.0, t / (0.00035 if kind == 'stamp' else 0.001))
            out.append(v * attack * release(t, duration - 0.008, 0.008))
        return out

    def chord(self, notes, when, gate, level, mellow=False, final=False):
        for n, midi in enumerate(notes):
            pan = -0.43 + 0.86 * n / max(1, len(notes) - 1)
            # Small strum before the cut; final chord is precisely simultaneous.
            at = when + (0 if final else n * 0.0014)
            self.place(self.piano(midi, gate, mellow, final), at,
                       level * (1 - 0.035 * (n % 3)), pan, 0.20, 'FM electric piano')

    def finish(self):
        # Short diffuse stereo room: damped parallel feedback delays.
        # Only echoes/release follow the stamp; there are no sequenced later notes.
        wet = [array('d', [0.0]) * FRAMES for _ in range(2)]
        for ch in range(2):
            for seconds in (0.0371, 0.0497, 0.0631, 0.0793):
                delay = round((seconds + ch * 0.0023) * SR)
                buf = array('d', [0.0]) * delay
                damp = 0.0
                feedback = 10 ** (-3 * delay / SR / 0.85)
                source = self.send[ch]
                dest = wet[ch]
                for i in range(FRAMES):
                    j = i % delay
                    v = buf[j]
                    damp = 0.58 * damp + 0.42 * v
                    buf[j] = source[i] + feedback * damp
                    dest[i] += v * 0.25
        peak = 0.0
        for ch in range(2):
            last_x = last_y = 0.0
            for i in range(FRAMES):
                t = i / SR
                x = self.dry[ch][i] + wet[ch][i]
                # Gentle tape-like soft saturation and a DC blocking highpass.
                x = math.tanh(x * 1.18) / 1.18
                y = x - last_x + 0.9975 * last_y
                last_x, last_y = x, y
                fade_in = min(1.0, t / 0.005)
                fade_out = release(t, 9.08, 0.82)
                y *= fade_in * fade_out
                self.dry[ch][i] = y
                peak = max(peak, abs(y))
        gain = 10 ** (-1.8 / 20) / peak
        pcm = array('h')
        for i in range(FRAMES):
            for ch in range(2):
                x = self.dry[ch][i] * gain
                # Triangular dither for PCM16, gated with fade to exact terminal silence.
                dither = (self.rng.random() - self.rng.random()) * release(i / SR, 9.08, 0.82)
                pcm.append(round(x * 32767 + dither) if i < round(9.9 * SR) else 0)
        if sys.byteorder != 'little':
            pcm.byteswap()
        return pcm


def compose(take):
    s = Studio(61423 if take == 'a' else 93287)
    if take == 'a':
        beat = 6.5 / 12
        chords = [(0, [55, 62, 66, 69, 71]), (4, [55, 59, 62, 66, 69]),
                  (8, [55, 61, 66, 71])]
        for b, notes in chords:
            s.chord(notes, b * beat, 1.4, 0.125 + b * 0.0018)
            s.chord(notes[1:], (b + 2.6) * beat, 0.4, 0.054)
        bass = [(0, 43, 1.8), (2.65, 50, 0.7), (4, 40, 1.7), (6.65, 47, 0.75),
                (8, 45, 1.5), (10.6, 40, 0.9), (12, 38, 3.5)]
        melody = [(0.65, 78, .7), (1.55, 81, .6), (2.60, 83, .6), (3.25, 81, .4),
                  (4.60, 79, .6), (5.60, 78, .5), (6.60, 74, .6), (7.25, 76, .4),
                  (8.60, 76, .5), (9.25, 81, .5), (10.0, 85, .5), (10.65, 83, .4),
                  (11.30, 81, .3), (12, 86, 2.1)]
        kicks = [(0, .19), (2.55, .11), (4, .20), (5.65, .10), (6.5, .14),
                 (8, .20), (10.5, .13)]
        snares = [(1, .14), (3, .15), (5, .15), (7, .16), (9, .16), (11, .17)]
        ghosts = [(2.7, .040), (6.7, .046), (10.7, .055)]
        beats = 12
        final_chord = [57, 62, 66, 71, 76]
    else:
        beat = 6.5 / 8
        chords = [(0, [53, 60, 63, 67, 68]), (2, [56, 60, 63, 65]),
                  (4, [56, 60, 61, 65]), (6, [55, 61, 65, 72])]
        for b, notes in chords:
            s.chord(notes, b * beat, 1.42, .132 + b * .002, mellow=True)
        bass = [(0, 41, 1.3), (1.62, 48, .23), (2, 37, 1.3), (3.62, 44, .23),
                (4, 46, 1.3), (5.62, 41, .23), (6, 39, 1.3), (7.62, 46, .20),
                (8, 44, 2.0)]
        melody = [(.62, 72, .28), (1, 75, .52), (2, 77, .72), (3, 75, .25),
                  (3.62, 72, .25), (4, 73, .48), (4.62, 72, .25), (5, 70, .60),
                  (6, 67, .35), (6.62, 75, .25), (7, 79, .55), (8, 80, 1.4)]
        kicks = [(0, .19), (1.62, .10), (2, .15), (3.62, .09),
                 (4, .20), (5.62, .11), (6, .16), (7.62, .09)]
        snares = [(1, .14), (3, .15), (5, .15), (7, .16)]
        ghosts = [(2.62, .036), (6.62, .041)]
        beats = 8
        final_chord = [56, 60, 63, 65, 70]

    for b, midi, duration in bass:
        s.place(s.bass(midi, duration * beat), b * beat,
                .20 if b == beats else (.115 if duration < 1 else .165), room=.035,
                kind='sine bass')
    for n, (b, midi, duration) in enumerate(melody):
        final = b == beats
        level = (.106 if take == 'a' else .115) * (1.05 if final else 0.83 + n % 3 * .055)
        s.place(s.bell(midi, duration * beat, final), b * beat, level,
                0 if final else (-.23 if n % 2 else .23), .22, 'glass chime')
    for kind, pattern in [('kick', kicks), ('snare', snares), ('snare', ghosts)]:
        for b, level in pattern:
            s.place(s.drum(kind), b * beat, level, -.06 if kind == 'snare' else 0,
                    .04, kind)
    for b in range(beats):
        for off, strength in [(0, .063), (.60 if take == 'a' else .62, .043)]:
            # The first half bar is lighter; hats gather gently under the push-in.
            gain = strength * (.62 + .38 * b / (beats - 1))
            s.place(s.drum('hat'), (b + off) * beat, gain, .30, .025, 'dusty hat')
    s.chord(final_chord, HIT, 1.85, .175, mellow=take == 'b', final=True)
    s.place(s.drum('stamp'), HIT, .40, 0, .045, 'end-card stamp')
    return s, 60 / beat


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'artifacts'
    output.mkdir(parents=True, exist_ok=True)
    for take in 'ab':
        studio, tempo = compose(take)
        pcm = studio.finish()
        wav_path = output / f'sting-{take}.wav'
        with wave.open(str(wav_path), 'wb') as w:
            w.setparams((2, 2, SR, FRAMES, 'NONE', 'not compressed'))
            w.writeframes(pcm.tobytes())
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                        '-i', str(wav_path), '-map_metadata', '-1', '-c:a', 'libmp3lame',
                        '-b:a', '320k', '-ar', str(SR), '-ac', '2', '-write_xing', '1',
                        str(output / f'sting-{take}.mp3')], check=True)
        print(json.dumps({'take': take, 'bpm': tempo, 'events': len(studio.events),
                          'last_attack_seconds': max(e['seconds'] for e in studio.events),
                          'output': str(wav_path)}), flush=True)


if __name__ == '__main__':
    main()
