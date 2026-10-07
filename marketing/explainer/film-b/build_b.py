#!/usr/bin/env python3
"""Explainer film B, "The bank and the swarm": assemble, encode and check.

ffmpeg/ffprobe plus the Python standard library, nothing else.

    python3 marketing/explainer/film-b/build_b.py --standins --aspect 16x9 --width 640 \
        --out artifacts/animatic-16x9.mp4

--standins draws flat ivory stand-ins for K1..K6 at the declared 1920x1080 (with hairline marks
for the 1:1 safe area, a K-index of ink ticks, K5's empty screen and K6's blank sheet) wherever
--keyframes has no real k?-*.png. Everything else is real: the note layers, the caption plates and
the end cards come from marketing/explainer/layers/ and marketing/kit/endcard/.

Timing contract: 40.000 s at 30 fps (1200 frames); HIT at frame 1095 (36.500 s) = two ivory frames,
then the end card from frame 1097 to 1199. All times below are seconds on the film clock.
"""
import argparse, json, math, os, shutil, struct, subprocess, sys, zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
LAYERS = os.path.join(ROOT, "marketing", "explainer", "layers")
ENDCARDS = os.path.join(ROOT, "marketing", "kit", "endcard")
FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "DejaVuSansMono.ttf")
GEOM = json.load(open(os.path.join(LAYERS, "geometry.json")))
PAL = GEOM["palette"]
HEX = {k: "0x" + v[1:] for k, v in PAL.items()}

FPS, TOTAL, HIT_F, FLASH_F = 30, 1200, 1095, 2          # 40.000 s; 36.500 s; two frames
KEYFRAMES = ["k1-bank", "k2-board", "k3-dissolve", "k4-swarm", "k5-converge", "k6-press"]

# Layout contract on the 1920x1080 keyframe (also drawn into the stand-ins).
SAFE_1x1 = (420, 0, 1080, 1080)                          # centre crop for 1:1
TICKS = (460, 80, 24, 40)                                # x0, y, size, pitch of the K-index ticks
SCREEN = (660, 280, 600, 360)                            # K5's empty framed screen (inner rect)
NOTE_S = 0.32                                            # note master -> keyframe pixels (fits the 1:1 crop)
NOTE_XY = (960 - GEOM["master"]["w"] * NOTE_S / 2, 120)  # (437.76, 120): note 1044.48 x 448
PORTRAIT_C = (NOTE_XY[0] + GEOM["portrait"]["innerEllipse"]["cx"] * NOTE_S,
              NOTE_XY[1] + GEOM["portrait"]["innerEllipse"]["cy"] * NOTE_S)   # (960.0, 364.48)

# Shots of the picture track (the scene): (keyframe, film start, film end, zoom from, zoom to, focus x, y)
SHOTS = [
    (0, 4.0, 9.5, 1.00, 1.06, 960, 600),     # K1: push toward the vault door
    (1, 8.5, 16.0, 1.00, 1.05, 960, 430),    # K2: push toward the standing figure and the coin
    (2, 14.0, 20.5, 1.00, 1.03, 960, 540),   # K3: the half-transformed room, barely moving
    (3, 19.0, 24.0, 1.08, 1.00, 960, 540),   # K4: pull back to show the wall floor to ceiling
]
XFADES = [("fade", 8.5, 1.0), ("lines", 14.0, 2.0), ("lines", 19.0, 1.5)]  # into shot i+1
K5_PUSH = (24.0, 31.0, 1.00, 1.08, SCREEN[0] + SCREEN[2] / 2, SCREEN[1] + SCREEN[3] / 2)
K6_PUSH = (34.0, 36.5, 1.00, 1.15) + PORTRAIT_C                           # ease-in to the hit

# The screen in K5: typed in the caption monospace, 40 ms a character.
Q_LINES = [("What is one IMD", 24.60), ("worth in dollars?", 25.30)]
FIGURE = ("1.2345", 28.80)          # last character lands on 29.000 s, the agreement note
TYPE_DT = 0.04
Q_FONT, FIG_FONT = 40, 110
Q_XY = [(SCREEN[0] + 40, SCREEN[1] + 34), (SCREEN[0] + 40, SCREEN[1] + 86)]
FIG_XY = (SCREEN[0] + 40, SCREEN[1] + 156)
FLOURISH = (29.10, 0.50, (SCREEN[0] + 40, SCREEN[1] + 290, 520, 50))   # start, length, box

# The note's assembly: stack order, start of each 0.20 s opacity ramp (film time).
ASSEMBLY = [(name, 31.0 + 0.30 * i) for i, name in enumerate(GEOM["stackOrder"])]
RAMP = 0.20

# Captions: (id, fade-in start, fade-in, fade-out start, fade-out). b1 is typed instead of faded in.
CAPTIONS = [("b1", 0.40, 0.0, 3.60, 0.40), ("b2", 16.00, 0.40, 22.60, 0.40),
            ("b3", 27.80, 0.30, 30.70, 0.30), ("b4", 32.60, 0.30, None, 0.0)]  # b4 ends on the cut
B1_TYPE = (0.40, TYPE_DT)
ADVANCE = 1233 / 2048 * 72          # DejaVu Sans Mono advance at 72 px; fits the plates (see storyboard)

# Per aspect, in reference pixels: canvas, scene scale and offset, caption scale and centre y, style.
ASPECTS = {
    "16x9": dict(ref=(1920, 1080), ground="ivory", scene=1.0, crop=None, at=(0, 0),
                 cap=1.0, cap_cy=864, style="card", end="endcard-1920x1080.png"),
    "1x1": dict(ref=(1080, 1080), ground="ivory", scene=1.0, crop=SAFE_1x1, at=(0, 0),
                cap=0.5625, cap_cy=880, style="card", end="endcard-1080x1080.png"),
    "9x16": dict(ref=(1080, 1920), ground="ink", scene=0.5625, crop=None, at=(0, 500),
                 cap=0.5625, cap_cy=1300, style="plain", end="endcard-1080x1920.png"),
}


def run(cmd, **kw):
    print("+", " ".join(cmd if len(" ".join(cmd)) < 400 else cmd[:8] + ["..."]), file=sys.stderr)
    return subprocess.run(cmd, check=True, **kw)


def ff(*args):
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *args])


def even(v):
    return int(round(v / 2.0)) * 2


# ---------- PNG writer and measurement helpers (stdlib) ----------

def write_png(path, w, h, rgba):
    raw = b"".join(b"\x00" + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def alpha_bbox(png, w, h):
    """Ink bounding box of a transparent plate, from its alpha channel."""
    a = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", png, "-vf", "alphaextract",
                        "-f", "rawvideo", "-pix_fmt", "gray", "-"], check=True, capture_output=True).stdout
    xs, ys = [], []
    for y in range(h):
        row = a[y * w:(y + 1) * w]
        hit = [x for x in range(w) if row[x] > 8]
        if hit:
            ys.append(y); xs += [hit[0], hit[-1]]
    return min(xs), min(ys), max(xs), max(ys)


# ---------- stand-ins ----------

def make_standin(path, k):
    """Flat ivory at 1920x1080 with hairline/ink marks: no text, palette only."""
    i = k + 1
    d = [f"drawbox=x={SAFE_1x1[0]}:y=0:w={SAFE_1x1[2]}:h=1080:color={HEX['hair']}:t=3"]
    for j in range(i):
        d.append(f"drawbox=x={TICKS[0] + TICKS[3] * j}:y={TICKS[1]}:w={TICKS[2]}:h={TICKS[2]}:color={HEX['ink']}:t=fill")
    if i == 5:   # the empty framed screen
        x, y, w, h = SCREEN
        d.append(f"drawbox=x={x - 8}:y={y - 8}:w={w + 16}:h={h + 16}:color={HEX['ink']}:t=6")
        d.append(f"drawbox=x={x - 20}:y={y - 20}:w={w + 40}:h={h + 40}:color={HEX['green']}:t=2")
    if i == 6:   # the blank sheet emerging from the slot: exactly where the note lands
        x, y = NOTE_XY
        nw, nh = round(GEOM['master']['w'] * NOTE_S), round(GEOM['master']['h'] * NOTE_S)
        d.append(f"drawbox=x={int(x) - 6}:y={y - 6}:w={nw + 12}:h={nh + 12}:color={HEX['hair']}:t=3")
        d.append(f"drawbox=x=400:y={y + nh + 20}:w=1120:h=14:color={HEX['ink']}:t=fill")   # the slot
    if i == 2:   # where the blank coin is held up
        d.append(f"drawbox=x=940:y=300:w=40:h=40:color={HEX['green']}:t=2")
    ff("-f", "lavfi", "-i", f"color=c={HEX['ivory']}:s=1920x1080", "-frames:v", "1",
       "-vf", ",".join(d), path)


# ---------- scene (picture track, 0 .. 36.5 s) at scene scale ks ----------

def zexpr(z0, z1, n):
    return f"({z0}+({z1}-{z0})*on/{max(n - 1, 1)})"


def is_clip(src):
    return src.lower().endswith((".mp4", ".mov", ".mkv"))


def still_or_clip(src, seconds):
    """Input args for a keyframe: a looped still, or an image-to-video clip at least `seconds` long."""
    if not is_clip(src):
        return ["-loop", "1", "-framerate", str(FPS), "-t", f"{seconds}", "-i", src]
    d = float(probe_json("-show_entries", "format=duration", src)["format"]["duration"])
    if d + 1e-3 < seconds:
        sys.exit(f"{src} is {d:.3f} s; this shot needs {seconds:.3f} s")
    return ["-i", src]


def clip_head(idx, n):
    """A clip conformed to 30 fps and cut to the shot's n frames (no-op for a looped still)."""
    return f"[{idx}:v]fps={FPS},trim=end_frame={n},setpts=PTS-STARTPTS"


def zoom_still(src, n, z0, z1, fx, fy, ks, U, out_label, idx):
    """A push on a still: zoompan of one image for n frames, fixed point (fx, fy).
    An image-to-video clip carries its own camera move: it is conformed and cut, not pushed."""
    sw, sh = even(1920 * ks), even(1080 * ks)
    if is_clip(src):
        return f"{clip_head(idx, n)},scale={sw}:{sh}:flags=lanczos,format=yuv444p,setsar=1[{out_label}]"
    px, py = fx * ks * U, fy * ks * U
    z = zexpr(z0, z1, n)
    return (f"[{idx}:v]scale={sw * U}:{sh * U}:flags=lanczos,format=yuv444p,"
            f"zoompan=z='{z}':x='{px}-{px}/zoom':y='{py}-{py}/zoom':d={n}:s={sw}x{sh}:fps={FPS},"
            f"setsar=1[{out_label}]")


# The line-by-line dissolve: a pixel turns from A to B when progress passes its threshold, which
# runs right to left across the frame and is staggered in 4-row groups of engraving lines.
# (No st()/ld(): xfade evaluates slices in parallel and the registers are shared.)
LINES_EXPR = ("A+(B-A)*clip(((1-P)-(0.8*(1-X/W)+0.05*mod(floor(Y/max(1,H/270)),4)))/0.05,0,1)")


def scene_bank(keys, ks, U, out):
    """4.0 .. 24.0: K1 push, dissolve to K2, line-by-line to K3 and K4."""
    inputs, chains = [], []
    for i, (k, t0, t1, z0, z1, fx, fy) in enumerate(SHOTS):
        inputs += still_or_clip(keys[k], t1 - t0) if is_clip(keys[k]) else ["-i", keys[k]]
        chains.append(zoom_still(keys[k], round((t1 - t0) * FPS), z0, z1, fx, fy, ks, U, f"s{i}", i))
    cur, start0 = "s0", SHOTS[0][1]
    for i, (kind, t, dur) in enumerate(XFADES):
        tr = "transition=fade" if kind == "fade" else f"transition=custom:expr='{LINES_EXPR}'"
        chains.append(f"[{cur}][s{i + 1}]xfade={tr}:duration={dur}:offset={t - start0:.3f}[x{i}]")
        cur = f"x{i}"
    n = round((24.0 - 4.0) * FPS)
    ff(*inputs, "-filter_complex", ";".join(chains), "-map", f"[{cur}]", "-frames:v", str(n),
       "-r", str(FPS), "-c:v", "ffv1", "-pix_fmt", "yuv444p", out)


def flourish_frames(dirpath, ks, U):
    """A signature flourish drawn on over 0.5 s: a code-drawn ink stroke, no letters."""
    t0, dur, (bx, by, bw, bh) = FLOURISH
    s = ks * U
    W, H = max(2, int(bw * s) + 8), max(2, int(bh * s) + 8)
    pts = []
    for j in range(400):
        u = j / 399
        x = bw * u - 26 * math.sin(2 * math.pi * 3 * u) * (1 - u)
        y = bh / 2 + (bh / 2 - 6) * math.sin(2 * math.pi * 3 * u + 1.2) * (1 - 0.7 * u)
        pts.append((4 + x * s, 4 + y * s))
    ink = bytes(int(PAL["ink"][i:i + 2], 16) for i in (1, 3, 5))
    r = max(1.0, 2.5 * s)
    n = round(dur * FPS)
    for f in range(n):
        buf = bytearray(W * H * 4)
        upto = int(len(pts) * (f + 1) / n)
        for (x, y) in pts[:upto]:
            for yy in range(int(y - r), int(y + r) + 1):
                for xx in range(int(x - r), int(x + r) + 1):
                    if 0 <= xx < W and 0 <= yy < H and (xx - x) ** 2 + (yy - y) ** 2 <= r * r:
                        o = (yy * W + xx) * 4
                        buf[o:o + 4] = ink + b"\xff"
        write_png(os.path.join(dirpath, f"fl_{f:03d}.png"), W, H, buf)
    return int(bx * s) - 4, int(by * s) - 4


def esc(t):
    return t.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'").replace("?", "\\?")


def scene_screen(keys, ks, U, work, out):
    """24.0 .. 31.0: K5, the question and the figure typed on the empty screen, the flourish, a push."""
    t0, t1, z0, z1, fx, fy = K5_PUSH
    n = round((t1 - t0) * FPS)
    sw, sh, s = even(1920 * ks), even(1080 * ks), ks * U
    fdir = os.path.join(work, "flourish"); os.makedirs(fdir, exist_ok=True)
    flx, fly = flourish_frames(fdir, ks, U)
    draws = []
    def typed(text, tstart, x, y, size, col):
        for i in range(len(text)):
            a, b = tstart + TYPE_DT * i - t0, tstart + TYPE_DT * (i + 1) - t0
            en = f"gte(t,{a:.4f})" if i == len(text) - 1 else f"between(t,{a:.4f},{b - 1e-4:.4f})"
            draws.append(f"drawtext=fontfile='{FONT}':text='{esc(text[:i + 1])}':x={x * s:.2f}:y={y * s:.2f}:"
                         f"fontsize={size * s:.2f}:fontcolor={HEX['ink']}:enable='{en}'")
    for (line, ts), (x, y) in zip(Q_LINES, Q_XY):
        typed(line, ts, x, y, Q_FONT, "ink")
    typed(FIGURE[0], FIGURE[1], FIG_XY[0], FIG_XY[1], FIG_FONT, "ink")
    fl_start = FLOURISH[0] - t0
    z = (f"if(lt(in,0),{z0},{z0}+({z1}-{z0})*in/{n - 1})")
    px, py = fx * s, fy * s
    g = (f"{clip_head(0, n)},scale={sw * U}:{sh * U}:flags=lanczos,format=yuv444p,{','.join(draws)}[typed];"
         f"[1:v]setpts=PTS+{fl_start}/TB[fl];"
         f"[typed][fl]overlay=x={flx}:y={fly}:eof_action=repeat[signed];"
         f"[signed]zoompan=z='{z}':x='{px}-{px}/zoom':y='{py}-{py}/zoom':d=1:s={sw}x{sh}:fps={FPS},setsar=1[v]")
    ff(*still_or_clip(keys[4], t1 - t0),
       "-framerate", str(FPS), "-i", os.path.join(fdir, "fl_%03d.png"),
       "-filter_complex", g, "-map", "[v]", "-frames:v", str(n), "-c:v", "ffv1", "-pix_fmt", "yuv444p", out)


def scene_press(keys, ks, U, work, out):
    """31.0 .. 36.5: K6, the note assembled from the layers in stack order, a push to the portrait."""
    t0, t1 = 31.0, 36.5
    n = round((t1 - t0) * FPS)
    sw, sh, s = even(1920 * ks), even(1080 * ks), ks * U
    nw, nh = round(GEOM["master"]["w"] * NOTE_S * s), round(GEOM["master"]["h"] * NOTE_S * s)
    nx, ny = round(NOTE_XY[0] * s), round(NOTE_XY[1] * s)
    inputs = still_or_clip(keys[5], t1 - t0)
    g = [f"{clip_head(0, n)},scale={sw * U}:{sh * U}:flags=lanczos,format=rgba[b0]"]
    for i, (name, ts) in enumerate(ASSEMBLY):
        inputs += ["-loop", "1", "-framerate", str(FPS), "-t", f"{t1 - t0}", "-i", os.path.join(LAYERS, name + ".png")]
        g.append(f"[{i + 1}:v]scale={nw}:{nh}:flags=area,format=rgba,"
                 f"fade=t=in:st={ts - t0:.3f}:d={RAMP}:alpha=1[l{i}]")
        g.append(f"[b{i}][l{i}]overlay=x={nx}:y={ny}:format=auto[b{i + 1}]")
    p0, p1, z0, z1, fx, fy = K6_PUSH
    a, b = round((p0 - t0) * FPS), round((p1 - t0) * FPS) - 1
    z = f"{z0}+({z1}-{z0})*pow(clip((in-{a})/{b - a},0,1),2)"
    px, py = fx * s, fy * s
    g.append(f"[b{len(ASSEMBLY)}]format=yuv444p,zoompan=z='{z}':x='{px}-{px}/zoom':y='{py}-{py}/zoom':"
             f"d=1:s={sw}x{sh}:fps={FPS},setsar=1[v]")
    ff(*inputs, "-filter_complex", ";".join(g), "-map", "[v]", "-frames:v", str(n),
       "-c:v", "ffv1", "-pix_fmt", "yuv444p", out)


def build_scene(keys, ks, U, work):
    sw, sh = even(1920 * ks), even(1080 * ks)
    parts = []
    p = os.path.join(work, "s0-card.mkv")
    ff("-f", "lavfi", "-i", f"color=c={HEX['ivory']}:s={sw}x{sh}:r={FPS}", "-frames:v", "120",
       "-c:v", "ffv1", "-pix_fmt", "yuv444p", p); parts.append(p)
    p = os.path.join(work, "s1-bank.mkv"); scene_bank(keys, ks, U, p); parts.append(p)
    p = os.path.join(work, "s2-screen.mkv"); scene_screen(keys, ks, U, work, p); parts.append(p)
    p = os.path.join(work, "s3-press.mkv"); scene_press(keys, ks, U, work, p); parts.append(p)
    lst = os.path.join(work, "scene.txt")
    open(lst, "w").write("".join(f"file '{q}'\n" for q in parts))
    out = os.path.join(work, "scene.mkv")
    ff("-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out)
    return out


# ---------- per aspect: captions, the hit, the end card, audio, encode ----------

def caption_card(work, cid, style):
    """The real plate; for style 'card' on an ivory card with a hairline rule (palette only)."""
    g = GEOM["captions"][cid]
    colour = "ivory" if style == "plain" else "ink"
    plate = os.path.join(LAYERS, f"caption-{cid}-{colour}.png")
    if style == "plain" or cid == "b1":
        return plate, alpha_bbox(plate, g["w"], g["h"])
    x0, y0, x1, y1 = alpha_bbox(plate, g["w"], g["h"])
    pad_x, pad_y = 48, 22
    cx, cy, cw, ch = x0 - pad_x, max(0, y0 - pad_y), x1 - x0 + 2 * pad_x, min(g["h"], y1 + pad_y) - max(0, y0 - pad_y)
    out = os.path.join(work, f"card-{cid}.png")
    ff("-f", "lavfi", "-i", f"color=c={HEX['ivory']}:s={cw}x{ch}", "-i", plate, "-frames:v", "1",
       "-filter_complex",
       f"[0:v]format=rgba,drawbox=x=0:y=0:w={cw}:h={ch}:color={HEX['hair']}:t=2,"
       f"pad={g['w']}:{g['h']}:{cx}:{cy}:color=black@0[c];[c][1:v]overlay=0:0:format=auto", out)
    return out, (x0, y0, x1, y1)


def assemble(scene, aspect, kout, work, music, out):
    A = ASPECTS[aspect]
    W, H = even(A["ref"][0] * kout), even(A["ref"][1] * kout)
    ks = A["scene"] * kout
    sw, sh = even(1920 * ks), even(1080 * ks)
    hit_t = HIT_F / FPS
    inputs = ["-i", scene]
    g = [f"color=c={HEX[A['ground']]}:s={W}x{H}:r={FPS}:d={hit_t}[ground]"]
    if A["crop"]:
        cx, cy, cw, ch = A["crop"]
        g.append(f"[0:v]crop={even(cw * ks)}:{even(ch * ks)}:{round(cx * ks)}:{round(cy * ks)},setsar=1[sc]")
    else:
        g.append("[0:v]setsar=1[sc]")
    g.append(f"[ground][sc]overlay=x={round(A['at'][0] * kout)}:y={round(A['at'][1] * kout)}:shortest=1[v0]")
    cur, idx = "v0", 1
    c = A["cap"] * kout
    for cid, tin, din, tout, dout in CAPTIONS:
        png, (x0, y0, x1, y1) = caption_card(work, cid, A["style"])
        gh = GEOM["captions"][cid]["h"]
        pw, ph = even(1920 * c), even(gh * c)
        px, py = round((W - pw) / 2), round(A["cap_cy"] * kout - ph / 2)
        inputs += ["-loop", "1", "-framerate", str(FPS), "-t", f"{hit_t}", "-i", png]
        f = f"[{idx}:v]scale={pw}:{ph}:flags=lanczos,format=rgba"
        if din: f += f",fade=t=in:st={tin}:d={din}:alpha=1"
        if dout: f += f",fade=t=out:st={tout}:d={dout}:alpha=1"
        g.append(f + f"[c{idx}]")
        en = f"between(t,{tin},{(tout + dout) if tout else hit_t})"
        g.append(f"[{cur}][c{idx}]overlay=x={px}:y={py}:enable='{en}'[v{idx}]")
        cur = f"v{idx}"; idx += 1
        if cid == "b1":   # typed: a cover in the ground colour slides right, an ink cursor leads it
            t_type, dt = B1_TYPE
            nchar = len(GEOM["captions"]["b1"]["text"])
            sx = 960 - nchar * ADVANCE / 2
            nexp = f"clip(floor((t-{t_type})/{dt}+1e-6)+1,0,{nchar})"
            cov_w, cov_h = even((x1 - sx + 60) * c), even((y1 - y0 + 16) * c)
            cov_y = py + round((y0 - 8) * c)
            ground = HEX[A["ground"]]
            cur_col = HEX["ivory"] if A["ground"] == "ink" else HEX["ink"]
            t_done = t_type + dt * nchar
            g.append(f"color=c={ground}:s={cov_w}x{cov_h}:r={FPS}:d={hit_t}[cov]")
            g.append(f"[{cur}][cov]overlay=x='{px}+({sx}+{ADVANCE}*{nexp})*{c}':y={cov_y}:"
                     f"enable='lt(t,{t_done})'[vc]")
            g.append(f"color=c={cur_col}:s={max(2, even(ADVANCE * 0.55 * c))}x{cov_h - even(8 * c)}:r={FPS}:d={hit_t}[cur]")
            g.append(f"[vc][cur]overlay=x='{px}+({sx}+{ADVANCE}*{nexp})*{c}':y={cov_y + round(4 * c)}:"
                     f"enable='between(t,0.15,{t_done})+between(t,{t_done},3.4)*lt(mod(t-{t_done},0.5),0.25)'[vcur]")
            cur = "vcur"
    # The hit: two ivory frames, then the end card to 40.000 s.
    n_end = TOTAL - HIT_F - FLASH_F
    inputs += ["-loop", "1", "-framerate", str(FPS), "-t", f"{n_end / FPS}", "-i", os.path.join(ENDCARDS, A["end"])]
    g.append(f"[{cur}]trim=end_frame={HIT_F},setpts=PTS-STARTPTS,format=yuv444p[main]")
    g.append(f"color=c={HEX['ivory']}:s={W}x{H}:r={FPS},trim=end_frame={FLASH_F},format=yuv444p[flash]")
    g.append(f"[{idx}:v]scale={W}:{H}:flags=lanczos,fps={FPS},trim=end_frame={n_end},setsar=1,format=yuv444p[end]")
    g.append("[main][flash][end]concat=n=3:v=1:a=0,setsar=1[v]")
    idx += 1
    if music:
        inputs += ["-i", music]
        g.append(f"[{idx}:a]aresample=48000,atrim=0:40,asetpts=PTS-STARTPTS[a]")
    else:
        g.append("anullsrc=r=48000:cl=stereo,atrim=0:40[a]")
    ff(*inputs, "-filter_complex", ";".join(g), "-map", "[v]", "-map", "[a]",
       "-frames:v", str(TOTAL), "-r", str(FPS),
       "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-profile:v", "high",
       "-g", "30", "-force_key_frames", f"{hit_t},{(HIT_F + FLASH_F) / FPS}",
       "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-t", "40", "-movflags", "+faststart", out)


# ---------- checks (ffprobe) ----------

def probe_json(*args):
    r = subprocess.run(["ffprobe", "-v", "error", "-of", "json", *args], check=True, capture_output=True, text=True)
    return json.loads(r.stdout)


def top_atoms(path):
    out, f = [], open(path, "rb")
    while True:
        h = f.read(8)
        if len(h) < 8: break
        size, typ = struct.unpack(">I4s", h)
        if size == 1: size = struct.unpack(">Q", f.read(8))[0]; f.seek(size - 16, 1)
        else: f.seek(size - 8, 1)
        out.append(typ.decode("latin1"))
        if size == 0: break
    return out


def frame_gray(path, t, w, h):
    return subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", f"{t:.4f}", "-i", path, "-frames:v", "1",
                           "-f", "rawvideo", "-pix_fmt", "gray", "-"], check=True, capture_output=True).stdout


def check(path, aspect, kout, music):
    A = ASPECTS[aspect]
    W, H = even(A["ref"][0] * kout), even(A["ref"][1] * kout)
    res, ok = {}, True
    def req(name, cond, val):
        nonlocal ok
        res[name] = {"ok": bool(cond), "value": val}
        ok &= bool(cond)
    s = probe_json("-count_frames", "-show_streams", "-show_format", path)
    v = [x for x in s["streams"] if x["codec_type"] == "video"][0]
    a = [x for x in s["streams"] if x["codec_type"] == "audio"]
    req("video_codec_h264", v["codec_name"] == "h264", v["codec_name"])
    req("pix_fmt_yuv420p", v["pix_fmt"] == "yuv420p", v["pix_fmt"])
    req("size", (v["width"], v["height"]) == (W, H), f"{v['width']}x{v['height']}")
    req("fps_30", v["r_frame_rate"] == "30/1" and v["avg_frame_rate"] == "30/1", v["avg_frame_rate"])
    req("frames_1200", int(v["nb_read_frames"]) == TOTAL, v["nb_read_frames"])
    req("video_duration_40.000", abs(float(v["duration"]) - 40.0) < 1e-3, v["duration"])
    req("audio_aac", bool(a) and a[0]["codec_name"] == "aac", a[0]["codec_name"] if a else None)
    req("audio_duration_40", bool(a) and abs(float(a[0]["duration"]) - 40.0) < 0.05, a[0]["duration"] if a else None)
    res["container_duration"] = {"ok": True, "value": s["format"]["duration"]}
    atoms = top_atoms(path)
    req("faststart_moov_before_mdat", atoms.index("moov") < atoms.index("mdat"), atoms)
    # The cut: per-frame luma range via ffprobe + signalstats. A flat ivory frame has YMAX-YMIN <= 6.
    fr = probe_json("-f", "lavfi", "-i", f"movie={path},signalstats",
                    "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YMIN,lavfi.signalstats.YMAX,lavfi.signalstats.YAVG")["frames"]
    flat = [i for i, f in enumerate(fr) if int(f["tags"]["lavfi.signalstats.YMAX"]) - int(f["tags"]["lavfi.signalstats.YMIN"]) <= 6
            and float(f["tags"]["lavfi.signalstats.YAVG"]) > 200]
    late = [i for i in flat if i > 900]
    req("hit_flash_frames_1095_1096", late == [HIT_F, HIT_F + 1], late)
    req("hit_pts_36.500", abs(float(fr[HIT_F]["pts_time"]) - 36.5) < 1e-6, fr[HIT_F]["pts_time"])
    req("frame_1094_not_flash", HIT_F - 1 not in flat, fr[HIT_F - 1]["tags"])
    # End card from frame 1097: PSNR against the PNG.
    ec = os.path.join(ENDCARDS, A["end"])
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", path, "-loop", "1", "-i", ec, "-filter_complex",
                        f"[0:v]trim=start_frame={HIT_F + FLASH_F},setpts=PTS-STARTPTS,format=yuv420p[a];"
                        f"[1:v]scale={W}:{H}:flags=lanczos,format=yuv420p,trim=end_frame={TOTAL - HIT_F - FLASH_F}[b];[a][b]psnr",
                        "-f", "null", "-"], capture_output=True, text=True)
    line = [l for l in r.stderr.splitlines() if "PSNR" in l][-1]
    avg = float(line.split("average:")[1].split()[0]) if "inf" not in line.split("average:")[1].split()[0] else 99.0
    req("endcard_psnr_gt_30dB", avg > 30, avg)
    # Captions: ink (or ivory on the 9:16 ground) in the caption band at each caption's midpoint, none between.
    band_y0 = int((A["cap_cy"] - 140 * A["cap"]) * kout); band_y1 = int((A["cap_cy"] + 140 * A["cap"]) * kout)
    def band_has_caption(t):
        g = frame_gray(path, t, W, H)
        px = [g[y * W + x] for y in range(band_y0, band_y1) for x in range(W)]
        return (min(px) < 90) if A["ground"] == "ivory" else (max(px) > 200)
    for cid, t in (("b1", 2.5), ("b2", 19.5), ("b3", 29.5), ("b4", 35.0)):
        req(f"caption_{cid}_present_at_{t}", band_has_caption(t), t)
    for t in (0.1, 12.0, 25.0, 31.5):
        req(f"no_caption_at_{t}", not band_has_caption(t), t)
    # Beats: count the K-index ticks (ink squares) at one time per keyframe (stand-ins only).
    if os.environ.get("FILMB_STANDINS") == "1" and aspect == "16x9":
        for k, t in ((1, 6.0), (2, 11.0), (3, 17.5), (4, 22.5), (5, 26.0), (6, 32.0)):
            g = frame_gray(path, t, W, H)
            rows = [g[y * W:(y + 1) * W] for y in range(0, int(115 * kout))]   # above the note (y >= 120)
            row = max(rows, key=lambda r: sum(1 for p in r if p < 90))   # the ticks' solid middle row
            best, inside = 0, False
            for p in row:
                if p < 90 and not inside: best += 1
                inside = p < 90
            req(f"beat_K{k}_at_{t}", best == k, best)
    # The note: present after its assembly, absent before 31.0.
    def note_pixels(t):
        g = frame_gray(path, t, W, H)
        ks = A["scene"] * kout
        x0 = int(NOTE_XY[0] * ks + A["at"][0] * kout - (A["crop"][0] * ks if A["crop"] else 0))
        y0, y1 = int((NOTE_XY[1] + 80) * ks + A["at"][1] * kout), int((NOTE_XY[1] + 370) * ks + A["at"][1] * kout)
        x1 = x0 + int(GEOM["master"]["w"] * NOTE_S * ks)
        x0, x1 = max(0, x0), min(W, x1)
        return sum(1 for y in range(y0, y1) for x in range(x0, x1) if g[y * W + x] < 170)
    n_before, n_after = note_pixels(31.0), note_pixels(34.0)
    req("note_assembled_by_34.0", n_after > 20 * n_before + 50, [n_before, n_after])
    if music:
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", path, "-af", "atrim=start=39.9,volumedetect",
                            "-vn", "-f", "null", "-"], capture_output=True, text=True)
        mv = [l for l in r.stderr.splitlines() if "max_volume" in l]
        req("audio_silent_after_39.9", mv and float(mv[-1].split(":")[1].split()[0]) <= -80, mv)
    return ok, res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aspect", choices=list(ASPECTS), default="16x9")
    ap.add_argument("--width", type=int, default=None, help="output width (default: full size)")
    ap.add_argument("--keyframes", default=os.path.join(ROOT, "marketing", "explainer", "film-b", "keyframes"))
    ap.add_argument("--standins", action="store_true", help="draw stand-ins for any missing keyframe")
    ap.add_argument("--music", default=None, help="anthem-a.wav or anthem-b.wav; silent AAC if absent")
    ap.add_argument("--supersample", type=int, default=2, help="zoompan works at this multiple of the output")
    ap.add_argument("--work", default=os.path.join(ROOT, "out", "film-b"))
    ap.add_argument("--out", required=True)
    o = ap.parse_args()
    A = ASPECTS[o.aspect]
    kout = (o.width or A["ref"][0]) / A["ref"][0]
    work = os.path.join(os.path.abspath(o.work), f"{o.aspect}-{o.width or 'full'}")
    shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
    keys = []
    for name in KEYFRAMES:
        clip = [os.path.join(o.keyframes, name + e) for e in (".mp4", ".mov")]
        p = next((c for c in clip if os.path.exists(c)), os.path.join(o.keyframes, name + ".png"))
        if not os.path.exists(p):
            if not o.standins: sys.exit(f"missing keyframe {p} (use --standins for the animatic)")
            p = os.path.join(work, name + "-standin.png"); make_standin(p, KEYFRAMES.index(name))
            os.environ["FILMB_STANDINS"] = "1"
        keys.append(p)
    scene = build_scene(keys, A["scene"] * kout, o.supersample, work)
    os.makedirs(os.path.dirname(os.path.abspath(o.out)), exist_ok=True)
    assemble(scene, o.aspect, kout, work, o.music, o.out)
    ok, res = check(o.out, o.aspect, kout, o.music)
    print(json.dumps(res, indent=1, default=str))
    print("ALL CHECKS PASS" if ok else "CHECKS FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
