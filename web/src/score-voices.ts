// Small sound parts both sites' scores share. See score.tsx.
import type { Bed, Kit } from "./score";
import { seeded } from "./score";

const whites = new WeakMap<BaseAudioContext, AudioBuffer>();
/** Six seconds of white noise, made once per context (seeded). The wind is made of it. */
function white(ac: BaseAudioContext): AudioBuffer {
  let b = whites.get(ac);
  if (b) return b;
  b = ac.createBuffer(1, ac.sampleRate * 6, ac.sampleRate);
  const d = b.getChannelData(0);
  const r = seeded(5);
  for (let k = 0; k < d.length; k++) d[k] = r() * 2 - 1;
  whites.set(ac, b);
  return b;
}

/**
 * A looping noise source sounding from `when`, starting `offset` seconds into the buffer so layers
 * never move together. An event's source starts with the event: a gain node is at full until its first
 * scheduled value, so a source running earlier would leak through at full level.
 */
function air(ac: BaseAudioContext, offset: number, when = 0): AudioBufferSourceNode {
  const src = ac.createBufferSource();
  src.buffer = white(ac);
  src.loop = true;
  src.start(when, offset);
  return src;
}

/** Slow wandering of an AudioParam: two sines of incommensurate periods, summed, so it never repeats. */
function wander(ac: BaseAudioContext, param: AudioParam, depth: number, periods: [number, number]) {
  for (const period of periods) {
    const o = ac.createOscillator();
    o.frequency.value = 1 / period;
    const g = ac.createGain();
    g.gain.value = depth / 2;
    o.connect(g).connect(param);
    o.start();
  }
}

/**
 * The wind: two layers of filtered noise, one per side, whose loudness and brightness wander in slow
 * gusts, and over them a faint whistle tuned to the scene (the root two and three octaves up and its
 * fifth), as wind sings across an edge. `body` is the band the wind sits in; retuned with the scene.
 */
export function wind(kit: Kit, body: number, level: number) {
  const { ac } = kit;
  const sides: [number, number, [number, number], [number, number]][] = [
    [-0.7, 0.3, [17.3, 41.9], [23.1, 53.7]],
    [0.7, 2.9, [19.9, 37.1], [29.3, 47.3]],
  ];
  for (const [pan, offset, gusts, sweeps] of sides) {
    const lp = ac.createBiquadFilter();
    lp.type = "bandpass";
    lp.Q.value = 0.9;
    lp.frequency.value = body;
    wander(ac, lp.frequency, body * 0.8, sweeps);
    const g = ac.createGain();
    g.gain.value = level;
    wander(ac, g.gain, level * 0.9, gusts);
    const p = ac.createStereoPanner();
    p.pan.value = pan;
    air(ac, offset).connect(lp).connect(g).connect(p).connect(kit.out);
  }
  // The whistle: narrow resonances on the scene's notes, each fading in and out on its own period.
  const whistles = [
    [4, 0.5, 31.7, 1.1],
    [6, 0.32, 43.3, 3.7],
    [8, 0.2, 59.9, 5.3],
  ].map(([ratio, share, period, offset]) => {
    const bp = ac.createBiquadFilter();
    bp.type = "bandpass";
    bp.Q.value = 28;
    bp.frequency.value = kit.voicing.root * ratio;
    // A little waver in pitch, as a real whistle has.
    wander(ac, bp.detune, 22, [7.1, 11.3]);
    const g = ac.createGain();
    g.gain.value = level * share * 2.2;
    wander(ac, g.gain, level * share * 4, [period, period * 1.618]);
    air(ac, offset).connect(bp).connect(g).connect(kit.room);
    return { bp, ratio };
  });
  return {
    retune: (v: { root: number }, at: number) => {
      for (const { bp, ratio } of whistles) bp.frequency.setTargetAtTime(v.root * ratio, at, 3);
    },
  };
}

/** A pitch from a scale position (any octave): position len is the scale's first note an octave up. */
export function pitch(kit: Kit, pos: number, octave: number): number {
  const { scale, root } = kit.voicing;
  const len = scale.length;
  const o = Math.floor(pos / len);
  return root * scale[((pos % len) + len) % len] * 2 ** (octave + o);
}

/**
 * A gust: the wind rising over `rise` and dying over `fall`, its band sweeping up and back down, and
 * crossing from one side to the other (which side it starts from is seeded).
 */
export function gust(kit: Kit, when: number, n: number, band: number, level: number, rise: number, fall: number) {
  const { ac } = kit;
  const r = seeded(17, n);
  const src = ac.createBufferSource();
  src.buffer = white(ac);
  src.loop = true;
  const bp = ac.createBiquadFilter();
  bp.type = "bandpass";
  bp.Q.value = 1.4;
  bp.frequency.setValueAtTime(band * 0.6, when);
  bp.frequency.exponentialRampToValueAtTime(band * (1.5 + r()), when + rise);
  bp.frequency.exponentialRampToValueAtTime(band * 0.5, when + rise + fall);
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(level, when + rise);
  g.gain.exponentialRampToValueAtTime(0.0001, when + rise + fall);
  const p = ac.createStereoPanner();
  const from = r() < 0.5 ? -0.8 : 0.8;
  p.pan.setValueAtTime(from, when);
  p.pan.linearRampToValueAtTime(-from, when + rise + fall);
  src.connect(bp).connect(g).connect(p).connect(kit.out);
  src.start(when, (n * 1.37) % 5);
  src.stop(when + rise + fall + 0.05);
}

/**
 * One wave: the swell building as a low roar that brightens, the break (a burst of hiss), then the
 * wash running back out, long and darkening. `size` 0..1 scales its height and length.
 */
export function wave(kit: Kit, when: number, n: number, size: number, level: number) {
  const { ac } = kit;
  const r = seeded(23, n);
  const build = 3 + 1.5 * size + r(),
    wash = 5 + 3 * size + 2 * r();
  const peak = level * (0.55 + 0.45 * size);
  const p = ac.createStereoPanner();
  p.pan.value = (r() * 2 - 1) * 0.6;
  p.connect(kit.out);
  // The roar: low noise whose filter opens as it builds and closes as it washes out.
  const roar = air(ac, (n * 0.71) % 5, when);
  const lp = ac.createBiquadFilter();
  lp.type = "lowpass";
  lp.Q.value = 0.6;
  lp.frequency.setValueAtTime(180, when);
  lp.frequency.exponentialRampToValueAtTime(900 + 900 * size, when + build);
  lp.frequency.exponentialRampToValueAtTime(220, when + build + wash);
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(peak, when + build);
  g.gain.exponentialRampToValueAtTime(0.0001, when + build + wash);
  roar.connect(lp).connect(g).connect(p);
  roar.stop(when + build + wash + 0.1);
  // The break: bright hiss at the crest, fading through the first of the wash (the foam).
  const crest = when + build - 0.25;
  const foam = air(ac, (n * 1.93) % 5, crest);
  const hp = ac.createBiquadFilter();
  hp.type = "highpass";
  hp.frequency.value = 2200;
  const fg = ac.createGain();
  fg.gain.value = 0;
  fg.gain.setValueAtTime(0.0001, crest);
  fg.gain.exponentialRampToValueAtTime(peak * 0.45, crest + 0.35);
  fg.gain.exponentialRampToValueAtTime(0.0001, crest + 0.35 + wash * 0.6);
  foam.connect(hp).connect(fg).connect(p);
  foam.stop(crest + wash + 0.5);
}

/** The sea between waves: a steady low surf, slowly rising and falling. */
function surf(kit: Kit, level: number) {
  const { ac } = kit;
  for (const [pan, offset] of [
    [-0.5, 1.3],
    [0.5, 3.1],
  ]) {
    const lp = ac.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.value = 320;
    wander(ac, lp.frequency, 160, [27.1, 43.9]);
    const g = ac.createGain();
    g.gain.value = level * 0.5;
    wander(ac, g.gain, level * 0.35, [19.3, 31.3]);
    const p = ac.createStereoPanner();
    p.pan.value = pan;
    air(ac, offset).connect(lp).connect(g).connect(p).connect(kit.out);
  }
}

const WAVE_EVERY = 10.7; // seconds between waves, before each one's own drift

/**
 * Rain: a soft hiss and the low body of it falling, a patter of tiny drops (a few to a dozen a second,
 * the density drifting), and now and then a nearer drip, tuned to the scene's scale.
 */
function rain(kit: Kit, level: number): Bed {
  const { ac } = kit;
  for (const [type, freq, share, pan, offset] of [
    ["bandpass", 3800, 0.3, -0.4, 0.9],
    ["lowpass", 700, 0.45, 0.4, 3.7],
  ] as const) {
    const f = ac.createBiquadFilter();
    f.type = type;
    f.frequency.value = freq;
    f.Q.value = 0.5;
    const g = ac.createGain();
    g.gain.value = level * share;
    wander(ac, g.gain, level * share * 0.5, [23.9, 37.7]);
    const p = ac.createStereoPanner();
    p.pan.value = pan;
    air(ac, offset).connect(f).connect(g).connect(p).connect(kit.out);
  }
  const SLOT = 0.125;
  return {
    retune: () => {},
    schedule: (k, from, to, at) => {
      for (let s = Math.ceil(from / SLOT); s * SLOT < to; s++) {
        const r = seeded(41, s);
        const wall = s * SLOT;
        const density = 0.55 + 0.45 * Math.sin((2 * Math.PI * wall) / 47.3);
        for (let d = 0; d < 2; d++) if (r() < density * 0.7) drop(k, at(wall + r() * SLOT), r, level);
        if (r() < 0.035) drip(k, at(wall + r() * SLOT), r, level);
      }
    },
  };
}

/** One small drop: a high plink that falls in pitch, a few milliseconds long. */
function drop(kit: Kit, when: number, r: () => number, level: number) {
  const { ac } = kit;
  const o = ac.createOscillator();
  const f = 1800 + 3400 * r();
  o.frequency.setValueAtTime(f, when);
  o.frequency.exponentialRampToValueAtTime(f * 0.55, when + 0.035);
  const g = ac.createGain();
  const decay = 0.02 + 0.04 * r();
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(level * (0.08 + 0.3 * r() * r()), when + 0.002);
  g.gain.exponentialRampToValueAtTime(0.0001, when + decay);
  const p = ac.createStereoPanner();
  p.pan.value = r() * 1.8 - 0.9;
  o.connect(g).connect(p).connect(kit.out);
  o.start(when);
  o.stop(when + decay + 0.01);
}

/** A nearer drip, from a gutter or a leaf: a clear tone on one of the scene's notes, mostly in the room. */
function drip(kit: Kit, when: number, r: () => number, level: number) {
  const { ac } = kit;
  const len = kit.voicing.scale.length;
  const o = ac.createOscillator();
  const f = pitch(kit, Math.floor(r() * len), 3);
  o.frequency.setValueAtTime(f * 1.06, when);
  o.frequency.exponentialRampToValueAtTime(f, when + 0.04);
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(level * 0.35, when + 0.003);
  g.gain.exponentialRampToValueAtTime(0.0001, when + 0.5);
  const p = ac.createStereoPanner();
  p.pan.value = r() * 1.2 - 0.6;
  o.connect(g).connect(p);
  p.connect(kit.room);
  p.connect(kit.out);
  o.start(when);
  o.stop(when + 0.55);
}

/** Distant thunder: a low roll that comes in two or three swells and fades for a long time. */
function thunder(kit: Kit, when: number, n: number, level: number) {
  const { ac } = kit;
  const r = seeded(43, n);
  const src = air(ac, (n * 2.3) % 5, when);
  const lp = ac.createBiquadFilter();
  lp.type = "lowpass";
  lp.Q.value = 0.7;
  lp.frequency.setValueAtTime(220, when);
  lp.frequency.exponentialRampToValueAtTime(90, when + 9);
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(level * 0.6, when + 0.5 + 0.4 * r());
  g.gain.exponentialRampToValueAtTime(level * 0.35, when + 1.6);
  g.gain.exponentialRampToValueAtTime(level, when + 2.4 + 0.6 * r());
  g.gain.exponentialRampToValueAtTime(level * 0.4, when + 4);
  g.gain.exponentialRampToValueAtTime(0.0001, when + 11);
  const p = ac.createStereoPanner();
  p.pan.value = r() * 1.2 - 0.6;
  src.connect(lp).connect(g).connect(p).connect(kit.out);
  src.stop(when + 11.1);
}

/** The bed for the kit's weather: wind, rain, or the sea with a wave every ten seconds or so. */
export function weather(kit: Kit, opts: { body: number; level: number }): Bed {
  if (kit.weather === "wind") return wind(kit, opts.body, opts.level);
  if (kit.weather === "rain") return rain(kit, opts.level);
  surf(kit, opts.level);
  return {
    retune: () => {},
    schedule: (k, from, to, at) => {
      for (let n = Math.ceil(from / WAVE_EVERY); n * WAVE_EVERY < to; n++) {
        const r = seeded(31, n);
        // Every seventh is a big one; the rest vary.
        const size = n % 7 === 0 ? 1 : 0.15 + 0.55 * r();
        wave(k, at(n * WAVE_EVERY + 2.5 * r()), n, size, opts.level * 2.2);
      }
    },
  };
}

/** The score's occasional big moment: a long gust, distant thunder, or a heavy set wave at sea. */
export function squall(kit: Kit, when: number, n: number, opts: { band: number; level: number }) {
  if (kit.weather === "wind") gust(kit, when, n, opts.band, opts.level, 4, 8);
  else if (kit.weather === "rain") thunder(kit, when, n, opts.level * 2.2);
  else wave(kit, when, n + 1e6, 1, opts.level * 1.6);
}

// ------------------------------------------------------------------ instrument parts

/** A gain envelope from silence: up over `a`, held for `h`, then dying away over about `d`. */
export function env(ac: BaseAudioContext, when: number, a: number, h: number, d: number, level: number): GainNode {
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0, when);
  g.gain.linearRampToValueAtTime(level, when + a);
  if (h > 0) g.gain.setValueAtTime(level, when + a + h);
  g.gain.setTargetAtTime(0, when + a + h, d / 5);
  return g;
}

/** Where a voice goes: a panner into the dry bus, with `wet` of it also sent straight to the room. */
export function place(kit: Kit, pan: number, wet = 0): AudioNode {
  const p = kit.ac.createStereoPanner();
  p.pan.value = Math.max(-1, Math.min(1, pan));
  p.connect(kit.out);
  if (wet) {
    const w = kit.ac.createGain();
    w.gain.value = wet;
    p.connect(w).connect(kit.room);
  }
  return p;
}

/** An oscillator (a basic wave, or a PeriodicWave) at `f`, sounding from `when` to `end`. */
export function osc(kit: Kit, wave: OscillatorType | PeriodicWave, f: number, when: number, end: number): OscillatorNode {
  const o = kit.ac.createOscillator();
  if (wave instanceof PeriodicWave) o.setPeriodicWave(wave);
  else o.type = wave;
  o.frequency.setValueAtTime(f, when);
  o.start(when);
  o.stop(end);
  return o;
}

const waves = new WeakMap<BaseAudioContext, Map<string, PeriodicWave>>();
/** A PeriodicWave from harmonic amplitudes (index 1 = fundamental), made once per context. */
export function timbre(ac: BaseAudioContext, name: string, harmonics: number[]): PeriodicWave {
  let m = waves.get(ac);
  if (!m) waves.set(ac, (m = new Map()));
  let w = m.get(name);
  if (!w) {
    w = ac.createPeriodicWave(new Float32Array(harmonics.length), new Float32Array(harmonics));
    m.set(name, w);
  }
  return w;
}

/** A short burst of filtered noise: a tick, a click, a sprocket, the scratch of a stroke. */
export function click(kit: Kit, dest: AudioNode, when: number, band: number, level: number, len: number) {
  const { ac } = kit;
  const src = air(ac, (when * 0.53) % 5, when);
  const bp = ac.createBiquadFilter();
  bp.type = "bandpass";
  bp.frequency.value = band;
  bp.Q.value = 1.2;
  const g = ac.createGain();
  g.gain.value = 0;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(level, when + 0.001);
  g.gain.exponentialRampToValueAtTime(0.0001, when + len);
  src.connect(bp).connect(g).connect(dest);
  src.stop(when + len + 0.01);
}

/** Noise for a voice to shape, from `when` to `end`. */
export function hiss(kit: Kit, when: number, end: number): AudioBufferSourceNode {
  const src = air(kit.ac, (when * 0.29) % 5, when);
  src.stop(end);
  return src;
}
