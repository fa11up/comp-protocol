"""Explainer film A, "The note is the diagram": the edit plan as data.

Every number here is the storyboard (artifacts/storyboard.md quotes them). Units:
- note space: master pixels of the 3264x1400 note (layers/geometry.json); x right, y down.
- camera: (cx, cy, Vh) = the master point at the frame centre and the master height the frame shows.
  Vh is interpolated geometrically (constant-speed zoom), cx/cy linearly, both by the key's easing.
- screen space (captions): pixels of the full-size frame for the aspect (1920x1080, 1080x1080, 1080x1920).
- rotation in degrees, clockwise on screen (y down).
Python standard library only.
"""
import json, math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LAYERS = ROOT / 'marketing/explainer/layers'
PLATES = ROOT / 'marketing/kit/plates'
GEO = json.loads((LAYERS / 'geometry.json').read_text())
PAL = GEO['palette']
FPS, TOTAL, HIT = 30, 40.0, 36.5
NFRAMES = round(TOTAL * FPS)            # 1200
HIT_FRAME = round(HIT * FPS)            # 1095; 1095-1096 ivory flash, 1097-1199 end card
ASPECTS = {'16x9': (1920, 1080), '1x1': (1080, 1080), '9x16': (1080, 1920)}

# ---------------------------------------------------------------- easing and keyframes
def smooth(u): return u * u * (3 - 2 * u)
EASE = {
    'linear': lambda u: u,
    'inOut': lambda u: 4 * u ** 3 if u < .5 else 1 - (2 - 2 * u) ** 3 / 2,   # cubic in-out
    'out': lambda u: 1 - (1 - u) ** 3,
    'in': lambda u: u ** 3,
    'launch': lambda u: .5 * u + .5 * smooth(u),     # the launch cut's push (marketing/launch/render.py)
    'step': lambda u: 0.0 if u < 1 else 1.0,
}

class K:
    """Keyframed scalar: K((t0, v0), (t1, v1, 'ease'), ...). Holds outside the keys; the ease of a
    key shapes the segment that ENDS on it (default cubic in-out)."""
    def __init__(self, *keys):
        self.keys = [(k[0], k[1], k[2] if len(k) > 2 else 'inOut') for k in keys]
    def __call__(self, t):
        ks = self.keys
        if t <= ks[0][0]: return ks[0][1]
        for (t0, v0, _), (t1, v1, e) in zip(ks, ks[1:]):
            if t < t1:
                return v0 + (v1 - v0) * EASE[e]((t - t0) / (t1 - t0))
        return ks[-1][1]

def const(v): return lambda t: v
def fade(*spans, base=0.0):
    """Alpha track from (t_start, t_end, target) ramps; cubic in-out."""
    keys = [(0.0, base)]; v = base
    for a, b, target in spans:
        keys += [(a, v), (b, target)]; v = target
    return K(*keys)

class Camera:
    """Keys (t, (cx, cy, Vh), ease); shake = K of a vertical offset in master px. An ease ending in
    '@' anchors the move on the key's target point (a push into it)."""
    def __init__(self, keys, shake=None):
        self.keys, self.shake = keys, shake or const(0.0)
    def __call__(self, t):
        ks = self.keys
        if t <= ks[0][0]: c = ks[0][1]
        elif t >= ks[-1][0]: c = ks[-1][1]
        else:
            for (t0, c0, _), (t1, c1, e) in zip(ks, ks[1:]):
                if t < t1:
                    anchored = e.endswith('@')
                    s = EASE[e.rstrip('@')]((t - t0) / (t1 - t0))
                    Vh = c0[2] * (c1[2] / c0[2]) ** s
                    if anchored:
                        # a push INTO the target point: the target's offset from frame centre, in
                        # frame heights, shrinks linearly with s while the zoom runs geometrically
                        c = (c1[0] - (c1[0] - c0[0]) / c0[2] * Vh * (1 - s),
                             c1[1] - (c1[1] - c0[1]) / c0[2] * Vh * (1 - s), Vh)
                    else:
                        c = (c0[0] + (c1[0] - c0[0]) * s, c0[1] + (c1[1] - c0[1]) * s, Vh)
                    break
        return c[0], c[1] + self.shake(t), c[2]

def fit(mx, my, Vh, sx, sy, ar):
    """Camera that puts master point (mx, my) at screen fraction (sx, sy) showing Vh master px."""
    return (mx - (sx - .5) * Vh * ar, my - (sy - .5) * Vh, Vh)

# ---------------------------------------------------------------- sprites
class Rig:
    """Placement of an image in note space (or screen space): native image pixel (u, v) lands at
    O + (u, v)/d, then scales (sx, sy) and rotates (rot) about pivot P, then translates (dx, dy)."""
    def __init__(self, O=(0, 0), d=1.0, P=None, sx=None, sy=None, rot=None, dx=None, dy=None,
                 space='note'):
        self.O, self.d, self.space = O, d, space
        self.P = P if P is not None else O
        self.sx, self.sy = sx or const(1.0), sy or sx or const(1.0)
        self.rot, self.dx, self.dy = rot or const(0.0), dx or const(0.0), dy or const(0.0)
    def affine(self, t):
        """2x3 matrix: native image px -> note (or screen) units."""
        sx, sy, r = self.sx(t), self.sy(t), math.radians(self.rot(t))
        c, s = math.cos(r), math.sin(r)
        a, b, cc, dd = c * sx / self.d, -s * sy / self.d, s * sx / self.d, c * sy / self.d
        Px, Py = self.P
        ox, oy = self.O[0] - Px, self.O[1] - Py
        tx = Px + c * sx * ox - s * sy * oy + self.dx(t)
        ty = Py + s * sx * ox + c * sy * oy + self.dy(t)
        return (a, b, tx, cc, dd, ty)

class Sprite:
    """src: ('file', path) | ('color', hex, w, h) in native px | ('seq', dir, n, first_frame)
    rect: sub-rectangle (x, y, w, h) of the file that is the image (default: whole file)."""
    def __init__(self, name, src, rig, alpha, size, rect=None, interp=None):
        self.name, self.src, self.rig, self.alpha, self.size = name, src, rig, alpha, size
        self.rect = rect or (0, 0) + tuple(size)

# ---------------------------------------------------------------- the film
NOTE = (3264, 1400)
PORTRAIT = GEO['portrait']; ROSETTE = GEO['rosette']; SEAL = GEO['seal']
OVAL_C = (PORTRAIT['innerEllipse']['cx'], PORTRAIT['innerEllipse']['cy'])     # (1632, 764)
DETAIL_D = 1 / PORTRAIT['scale']                 # portrait-detail px per master px (2.1645)
DETAIL_O = (PORTRAIT['x'], PORTRAIT['y'])         # crop (204, 24, 1640, 2000) of the 2048 plate
EYE = (292, 708, 1180, 287)                       # eye band in the 1640x2000 crop (launch render)
SERIAL_TEXT_Y = (1173, 1211)
GLYPHS = [(727, 747), (752, 775), (780, 802), (832, 854), (859, 881), (885, 907), (912, 934),
          (938, 960), (965, 987), (991, 1013), (1019, 1040), (1069, 1094)]   # measured, left strip
STRIP2_DX = 2171 - 727                            # the right strip's text is the left one + 1444

def framings(aspect):
    W, H = ASPECTS[aspect]; ar = W / H
    if aspect == '16x9':
        return dict(
            WIDE0=(1632, 700, 2160),                        # note 0.85 of frame width, centred
            OVAL=fit(*OVAL_C, 1593, .5, .40, ar),            # oval 0.58 H tall, upper frame
            WIDEC=fit(1632, 700, 2160, .5, .42, ar),         # whole note, lifted over the caption
            ROS=(1231, 700, 1385), FULL=(1632, 700, 1400), SEAL=(2033, 700, 1385),
            STRIP=(905, 1120, 560),                          # the serial strip, close, while the figure types
            ROW=fit(1632, 700, 4050, .5, .25, ar),
            END=(1632, 764, 683 * 9 / 16))                  # the launch cut's end framing
    if aspect == '1x1':
        return dict(
            WIDE0=(1632, 700, 3627), OVAL=fit(*OVAL_C, 1540, .5, .40, ar),
            WIDEC=fit(1632, 700, 3627, .5, .42, ar),
            ROS=(724, 775, 1250), FULL=(1632, 700, 1400), SEAL=(2540, 775, 1250),
            STRIP=(905, 950, 900),
            ROW=fit(1632, 700, 4600, .5, .33, ar), END=(1632, 764, 577.5))
    return dict(
        WIDE0=(1632, 700, 6307), OVAL=fit(*OVAL_C, 1682, .5, .42, ar),
        WIDEC=fit(1632, 700, 6307, .5, .42, ar),
        ROS=(724, 700, 1400), FULL=(1632, 700, 1400), SEAL=(2540, 700, 1400),
        STRIP=(905, 760, 1780),
        ROW=fit(1632, 700, 7600, .5, .36, ar), END=(1632, 764, 1244))

def stage4(aspect):
    """Beat 4: where the two other notes stand, the line, and where the falling note goes."""
    if aspect == '16x9':
        return dict(other=(1632 - 2850, 760), second=(1632 + 2850, 760), line_y=1631,
                    fall=(0, 1420), pull=(4500, 300))
    return dict(other=(1632, 700 - 1250), second=(1632 + 300, 1950), line_y=1700,
                fall=(0, 450), pull=(1800, 3800))

def caption_place(aspect, lines):
    """(scale, top y) of a 1920-wide caption plate in screen px."""
    W, H = ASPECTS[aspect]
    if aspect == '16x9': return 1.0, (880 if lines == 1 else 800)
    sc = W / 1920
    if aspect == '1x1': return sc, (938 if lines == 1 else 901)
    return sc, 1536

def build(aspect, kicker='a5'):
    W, H = ASPECTS[aspect]
    F = framings(aspect); S4 = stage4(aspect)
    cam = Camera([
        (0.0, F['WIDE0'], 'linear'), (3.0, F['WIDE0'], 'linear'),
        (4.3, F['OVAL'], 'inOut'), (6.5, F['OVAL'], 'linear'),
        (8.6, F['WIDEC'], 'inOut'), (11.0, F['WIDEC'][:2] + (F['WIDEC'][2] * .972,), 'linear'),
        (12.0, F['ROS'], 'inOut'), (16.6, F['ROS'][:2] + (F['ROS'][2] * .99,), 'linear'),
        (17.4, F['STRIP'], 'inOut'), (18.5, F['STRIP'][:2] + (F['STRIP'][2] * .97,), 'linear'),   # follow the medallion along the strip
        (19.6, F['FULL'], 'inOut'), (20.0, F['FULL'], 'linear'),
        (21.0, F['SEAL'], 'inOut'), (26.8, F['SEAL'][:2] + (F['SEAL'][2] * .98,), 'linear'),
        (28.0, F['WIDEC'], 'inOut'), (28.9, F['WIDEC'], 'linear'),
        (30.0, F['ROW'], 'inOut'), (33.5, F['ROW'][:2] + (F['ROW'][2] * .985,), 'linear'),
        (36.5, F['END'], 'launch@')],
        shake=K((22.30, 0), (22.333, 10, 'linear'), (22.367, -6, 'linear'), (22.40, 3, 'linear'),
                (22.433, 0, 'linear')))

    sprites = []
    def add(*a, **k): sprites.append(Sprite(*a, **k)); return sprites[-1]
    note = Rig()                                          # the main note never moves...
    main = Rig(P=(1632, 700), rot=K((29.0, 0), (30.0, -2), (31.5, -2), (32.3, 0, 'out')))
    # ...except in beat 4, where it leans with the others. Before 29.0 `main` is the identity.

    # --- the note's layers (stackOrder), with the isolate / reassemble alphas of each beat
    every = ['paper', 'border', 'rosette', 'portrait', 'seal', 'corners', 'banner', 'serials']
    keep = {  # layers that stay while the beat isolates its element
        1: {'portrait'}, 2: {'paper', 'rosette'}, 3: {'paper', 'seal'}, 4: {'paper', 'corners'}}
    def iso(name, beat, out, back, d=.6):
        return [] if name in keep[beat] else [(out, out + d, 0.0), (back, back + d, 1.0)]
    for name in every:
        spans = (iso(name, 1, 3.0, 6.45, .5) + iso(name, 2, 11.0, 18.8) + iso(name, 3, 20.3, 26.8)
                 + iso(name, 4, 28.0, 28.9, .4))
        if name == 'rosette':   # the rosette itself leaves while its spinning copy does the work
            spans = iso(name, 1, 3.0, 6.45, .5) + [(12.15, 12.2, 0.0), (19.25, 19.3, 1.0)] \
                + iso(name, 3, 20.3, 26.8) + iso(name, 4, 28.0, 28.9, .4)
        if name == 'portrait':
            spans = [(6.4, 6.4, 0.0), (8.3, 8.3, 1.0)] + spans
        add(name, ('file', LAYERS / f'{name}.png'), main, fade(*spans, base=1.0), NOTE)
        if name == 'serials':
            # beat 2: the empty strip and the typed glyphs sit where the serials were
            add('serials-empty', ('file', LAYERS / 'serials-empty.png'), main,
                fade((16.6, 16.9, 1.0), (19.4, 19.45, 0.0)), NOTE)
            for strip, dxs in (('L', 0), ('R', STRIP2_DX)):
                for i, (g0, g1) in enumerate(GLYPHS):
                    x0 = g0 - 2 + dxs; x1 = g1 + 2 + dxs
                    t_on = 17.3 + 1.2 * (g0 - 700) / 410          # as the figure passes the glyph
                    rect = (x0, SERIAL_TEXT_Y[0], x1 - x0, SERIAL_TEXT_Y[1] - SERIAL_TEXT_Y[0])
                    add(f'type{strip}{i:02d}', ('file', LAYERS / 'serials.png'),
                        Rig(O=rect[:2]), fade((t_on, t_on + 1 / 30, 1.0), (19.4, 19.45, 0.0)),
                        rect[2:], rect=rect)

    # --- beat 1: four ink covers hold the printing back to the oval's box, then open outward;
    # the side covers run full height, the top and bottom ones full width. The portrait is
    # drawn again above them while they are on (and the stacked one hides, so it is not doubled).
    ox0, oy0 = PORTRAIT['x'], PORTRAIT['y']; ox1, oy1 = ox0 + PORTRAIT['w'], oy0 + PORTRAIT['h']
    on = fade((6.4, 6.4, 1.0), (8.3, 8.3, 0.0))
    big = 9000
    def cover(name, O, dx=None, dy=None):
        add(name, ('color', PAL['ink'], big, big), Rig(O=O, dx=dx, dy=dy), on, (big, big))
    cover('coverT', (-4000, oy0 - big), dy=K((6.5, 0), (8.3, -200 - oy0)))
    cover('coverB', (-4000, oy1), dy=K((6.5, 0), (8.3, 1600 - oy1)))
    cover('coverL', (ox0 - big, -4000), dx=K((6.5, 0), (8.3, -200 - ox0)))
    cover('coverR', (ox1, -4000), dx=K((6.5, 0), (8.3, 3464 - ox1)))
    add('portrait-top', ('file', LAYERS / 'portrait.png'), main, on, NOTE)

    # the coin: 800 px canvas, R 360 -> 300 master px, rolls in from the left
    coin_d = 360 / 300
    x_in = K((4.3, -1100 - OVAL_C[0]), (5.5, 0, 'out'))
    roll = lambda t: math.degrees(x_in(t) / 300)
    shrink = K((9.4, 1.0), (10.2, 0.0, 'in'))
    flip_a = K((5.9, 1.0), (6.2, 0.0, 'in'))
    flip_b = K((6.2, 0.0), (6.5, 1.0, 'out'))
    co = (OVAL_C[0] - 400 / coin_d, OVAL_C[1] - 400 / coin_d)
    add('coin-imd', ('file', LAYERS / 'coin-imd.png'),
        Rig(O=co, d=coin_d, P=OVAL_C, sx=lambda t: max(flip_a(t), 1e-3), sy=const(1.0),
            rot=roll, dx=x_in), fade((4.3, 4.31, 1.0), (6.19, 6.2, 0.0)), (800, 800))
    add('coin-simd', ('file', LAYERS / 'coin-simd.png'),
        Rig(O=co, d=coin_d, P=OVAL_C, sx=lambda t: max(flip_b(t) * shrink(t), 1e-3),
            sy=lambda t: max(shrink(t), 1e-3)), fade((6.2, 6.21, 1.0), (10.15, 10.2, 0.0)), (800, 800))

    # --- beat 2: the rosette spins, its ghost counter-spins, they converge to a medallion,
    # a flourish signs it, the medallion types the serial strip and goes home.
    rc = (ROSETTE['cx'], ROSETTE['cy'])
    conv = K((13.8, 1.0), (15.0, 0.16, 'in'), (18.5, 0.16), (19.3, 1.0, 'out'))
    travel_x = K((16.9, 0), (17.3, 700 - rc[0]), (18.5, 1110 - rc[0], 'linear'), (19.3, 0, 'inOut'))
    travel_y = K((16.9, 0), (17.3, 1196 - rc[1]), (18.5, 1196 - rc[1], 'linear'), (19.3, 0, 'inOut'))
    spin = K((12.2, 0), (15.0, 200, 'in'), (19.3, 360, 'out'))
    add('rosette-ghost', ('file', LAYERS / 'rosette.png'),
        Rig(P=rc, sx=conv, rot=lambda t: -spin(t)), fade((12.2, 12.7, .55), (14.4, 15.0, 0.0)), NOTE)
    add('rosette-spin', ('file', LAYERS / 'rosette.png'),
        Rig(P=rc, sx=conv, rot=spin, dx=travel_x, dy=travel_y),
        fade((12.1, 12.15, 1.0), (19.3, 19.35, 0.0)), NOTE)
    fl_w, fl_h, fl_d = 560, 200, 2.0
    add('flourish', ('seq', 'flourish', 27, 450), Rig(O=(rc[0] - fl_w / 2, rc[1] + 70), d=fl_d),
        fade((15.0, 15.01, 1.0), (16.9, 17.2, 0.0)), (round(fl_w * fl_d), round(fl_h * fl_d)))

    # --- beat 3: the stamp
    sc = (SEAL['cx'], SEAL['cy'])
    add('seal-stamp', ('file', LAYERS / 'seal-stamp.png'),
        Rig(O=(sc[0] - 500, sc[1] - 500), P=sc,
            sx=K((21.0, 1.35), (22.1, 1.30), (22.3, 1.0, 'in')),
            rot=K((21.0, -12), (22.1, -8), (22.3, 0, 'in')),
            dy=K((21.0, -110), (22.1, -110), (22.3, 0, 'in'))),
        fade((21.0, 21.4, 1.0), (25.6, 26.4, 0.0)), (1000, 1000))

    # --- beat 4: the other notes, the line, the falling note, the flood
    oth = S4['other']; sec = S4['second']
    side_alpha = fade((28.9, 29.4, 1.0), (33.5, 33.5, 1.0))
    add('note-other', ('stack',), Rig(O=(oth[0] - 1632 * .7, oth[1] - 700 * .7), d=1 / .7,
        P=oth, rot=K((29.0, 0), (30.0, -4), (31.5, -4), (32.3, 0, 'out'))), side_alpha, NOTE)
    line_sx = K((29.3, 0.0), (29.9, 1.0, 'out'))
    add('line', ('color', PAL['hair'], 12000, 8),
        Rig(O=(1632 - 6000, S4['line_y'] - 4), P=(1632, S4['line_y']), sx=lambda t: max(line_sx(t), 1e-3), sy=const(1.0)),
        fade((29.3, 29.31, 1.0)), (12000, 8))
    fall_dx = K((30.0, 0), (30.8, S4['fall'][0]), (31.1, S4['fall'][0]), (31.6, S4['fall'][0] + S4['pull'][0], 'in'))
    fall_dy = K((30.0, 0), (30.8, S4['fall'][1]), (31.1, S4['fall'][1]), (31.6, S4['fall'][1] + S4['pull'][1], 'in'))
    fall_rot = K((29.0, 0), (30.0, 3), (30.8, 8), (31.1, 8), (31.6, 25, 'in'))
    flat = Rig(O=(sec[0] - 1632 * .7, sec[1] - 700 * .7), d=1 / .7, P=sec, rot=fall_rot, dx=fall_dx, dy=fall_dy)
    add('note-second', ('stack',), flat, fade((28.9, 29.4, 1.0), (30.0, 30.4, 0.0)), NOTE)
    # the angle plate: its note spans 1536 px of 1920 (measured in prep) and is scaled so its
    # width matches the flat second note (0.7 of the master width); centred on the same pivot
    ang_d = 1536 / (3264 * .7)      # measured bbox (192,121)-(1727,957), centre ~(960,539)
    ang = Rig(O=(sec[0] - 960 / ang_d, sec[1] - 540 / ang_d), d=ang_d, P=sec, rot=fall_rot, dx=fall_dx, dy=fall_dy)
    add('note-angle', ('angle',), ang, fade((30.0, 30.4, 1.0), (31.6, 31.6, 0.0)), (1920, 1080))
    add('note-flood', ('flood',), ang, fade((30.6, 31.1, 1.0), (31.6, 31.6, 0.0)), (1920, 1080))

    # --- the push: the high-resolution portrait over the layer, then the blink in the eye band
    add('portrait-detail', ('detail',), Rig(O=DETAIL_O, d=DETAIL_D, P=(1632, 700), rot=main.rot),
        fade((33.45, 33.5, 1.0)), (1640, 2000))
    TB = HIT - 1.05                           # the launch cut's blink, same offset from the hit
    away = ['portrait-detail', 'blink-075', 'blink-050', 'blink-025', 'blink-000']
    look = ['portrait-look', 'blink-look-075', 'blink-look-050', 'blink-look-025', 'blink-000']
    def blink_weights(t):
        """{plate: weight} for the eye band at time t (crossfade between quarter drawings)."""
        u = t - TB
        if u < 0: return {away[0]: 1.0}
        seq, v = (away, min(u / .12, 1) * 4) if u < .16 else \
                 (look, (1 - (u - .16) / .16) * 4) if u < .32 else (look, 0.0)
        lo = min(4, int(v)); hi = min(4, lo + 1); a = v - lo
        w = {seq[lo]: 1 - a}; w[seq[hi]] = w.get(seq[hi], 0) + a
        return w
    order = away + look[:4]                    # stacking order of the band sprites
    def band_alpha(name):
        def f(t):
            w = blink_weights(t)
            if t < TB - .05 or name not in w: return 0.0
            # draw-order crossfade: the lower plate opaque, the upper one at its share
            names = sorted(w, key=order.index)
            if len(names) == 1: return 1.0
            lo, hi = names
            return 1.0 if name == lo else w[hi]
        return f
    ex = (DETAIL_O[0] + EYE[0] / DETAIL_D, DETAIL_O[1] + EYE[1] / DETAIL_D)
    for name in order:
        add('eye-' + name, ('file', PLATES / f'{name}.png'), Rig(O=ex, d=DETAIL_D),
            band_alpha(name), EYE[2:], rect=(204 + EYE[0], 24 + EYE[1], EYE[2], EYE[3]))

    # --- captions (screen space): fade in 0.5 s with a 12 px rise, fade out 0.5 s in place
    caps = [('a1', 3.8, 6.5, 'ivory'), ('a1b', 7.0, 10.2, 'ivory'), ('a2', 11.7, 16.4, 'ink'), ('a3', 21.0, 26.3, 'ink'),
            ('a4', 28.3, 31.1, 'ivory'), (kicker, 31.65, 34.35, 'ivory')]
    for cid, t_in, t_out, tone in caps:
        info = GEO['captions'][cid]; lines = info['text'].count('\n') + 1
        csc, top = caption_place(aspect, lines)
        add(f'caption-{cid}', ('file', LAYERS / f'caption-{cid}-{tone}.png'),
            Rig(O=(0, top), d=1 / csc, space='screen', dy=K((t_in, 12), (t_in + .5, 0, 'out'))),
            fade((t_in, t_in + .5, 1.0), (t_out, t_out + .4, 0.0)), (info['w'], info['h']))
    return dict(camera=cam, sprites=sprites, captions=caps, framings=F, stage=S4, size=(W, H))
