#!/usr/bin/env python3
"""Renders explainer film A from the layers. Python standard library + FFmpeg (libx264, aac).

  python3 marketing/explainer/film-a/render.py --aspect 16x9 --width 640 --out artifacts/animatic-16x9.mp4
  python3 marketing/explainer/film-a/render.py --aspect 16x9 --music anthem-a.wav --out film-a-16x9.mp4
  (--resume continues an interrupted run from its finished 1 s segments)

Every sprite (a layer, a plate, a caption plate or a palette-coloured rectangle) is cropped to the part
that can be seen in a segment (1 s, halved while any scale changes more than 2x), pre-scaled once with
lanczos, then placed in each frame by FFmpeg's `perspective` filter (sense=destination) at the corners
plan.py gives for that frame, faded by `colorchannelmixer=aa`, and stacked on ink. One small FFmpeg graph
per frame with constant values: `perspective`'s per-frame `in` counter proved unreliable (it stays at one
value behind `loop`), so nothing depends on it. The note is drawn layer by layer, never as one picture.
Frames are composited at 2x and reduced. Then: 2 ivory frames at 36.500 s, the end card to 40.000 s,
H.264 yuv420p + AAC, +faststart. check.py measures the result.
"""
import argparse, math, os, shutil, subprocess as sp, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import plan
from plan import FPS, NFRAMES, HIT_FRAME, PAL, ROOT

FF = os.environ.get('FFMPEG', 'ffmpeg')
SS = 2                      # supersampling of the composite

def run(args, **kw):
    return sp.run([FF, '-y', '-v', 'error', *map(str, args)], check=True, **kw)

def raw(path, crop=None):
    vf = ['-vf', f'crop={crop[2]}:{crop[3]}:{crop[0]}:{crop[1]}'] if crop else []
    return sp.run([FF, '-v', 'error', '-i', str(path), *vf, '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'],
                  check=True, capture_output=True).stdout

def write_png(path, data, w, h):
    run(['-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{w}x{h}', '-i', '-', '-frames:v', 1, '-update', 1,
         path], input=bytes(data))

def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))

# ------------------------------------------------------------------ preparation (cached)
def prep(work):
    """Derived images, all from files in the tree. Returns {kind: path} and measurements."""
    work.mkdir(parents=True, exist_ok=True)
    meas = {}
    L, P = plan.LAYERS, plan.PLATES
    # the whole note stacked from its layers (for the two other notes of beat 4), and the check
    stack = work / 'stack.png'
    if not stack.exists():
        names = plan.GEO['stackOrder']
        ins = sum((['-i', L / f'{n}.png'] for n in names), [])
        g = ''.join(f'[{"0:v" if i == 1 else f"o{i - 1}"}][{i}:v]overlay=format=auto[o{i}];'
                    for i in range(1, len(names)))
        run([*ins, '-filter_complex', g + f'[o{len(names) - 1}]format=rgba', '-frames:v', 1, '-update', 1, stack])
    a, b = raw(stack), raw(P / 'note-master.png')
    diff = [abs(x - y) for x, y in zip(a, b)]
    meas['stack_vs_master'] = dict(max_channel_delta=max(diff),
                                   differing_pixels=sum(1 for i in range(0, len(diff), 4) if max(diff[i:i + 4]) > 2))
    # the angle plate's note, cut from its ink ground by a flood fill from the edges, and its flood
    cut, flood = work / 'angle-cut.png', work / 'flood.png'
    if not (cut.exists() and flood.exists()):
        w, h = 1920, 1080
        d = bytearray(raw(P / 'note-angle-16x9.png'))
        ink = hexrgb(PAL['ink'])
        near = lambda i: abs(d[i] - ink[0]) + abs(d[i + 1] - ink[1]) + abs(d[i + 2] - ink[2]) < 40
        bg = bytearray(w * h); stackq = [(x, y) for x in range(w) for y in (0, h - 1)] + \
                                        [(x, y) for y in range(h) for x in (0, w - 1)]
        while stackq:
            x, y = stackq.pop()
            p = y * w + x
            if bg[p] or not near(4 * p): continue
            bg[p] = 1
            if x > 0: stackq.append((x - 1, y))
            if x < w - 1: stackq.append((x + 1, y))
            if y > 0: stackq.append((x, y - 1))
            if y < h - 1: stackq.append((x, y + 1))
        xs = [p % w for p in range(w * h) if not bg[p]]; ys = [p // w for p in range(w * h) if not bg[p]]
        meas['angle_note_bbox'] = (min(xs), min(ys), max(xs), max(ys))
        g = hexrgb(PAL['green']); fl = bytearray(4 * w * h)
        for p in range(w * h):
            av = 0 if bg[p] else 255
            d[4 * p + 3] = av
            fl[4 * p:4 * p + 4] = bytes((g[0], g[1], g[2], av))
        write_png(cut, d, w, h); write_png(flood, fl, w, h)
        (work / 'angle-bbox.txt').write_text(' '.join(map(str, meas['angle_note_bbox'])))
    meas['angle_note_bbox'] = tuple(map(int, (work / 'angle-bbox.txt').read_text().split()))
    # portrait-detail crop with the launch cut's feathered ellipse (excludes the plate's ink corners)
    det = work / 'detail.png'
    if not det.exists():
        w, h = 1640, 2000
        d = bytearray(raw(P / 'portrait-detail.png', (204, 24, w, h)))
        cx, cy, rx, ry = w / 2, h / 2, w / 2 + 18, h / 2 - 8
        for y in range(h):
            for x in range(w):
                v = (1 - math.hypot((x - cx) / rx, (y - cy) / ry)) / .012
                d[4 * (y * w + x) + 3] = 255 if v >= 1 else 0 if v <= 0 else round(255 * v)
        write_png(det, d, w, h)
    # the signature flourish: an ink pen line, drawn over 27 frames (no letters)
    fdir = work / 'flourish'
    if not (fdir / '0026.png').exists():
        fdir.mkdir(exist_ok=True)
        w, h, D = 1120, 400, 2.0
        pts = []
        for i in range(4001):
            s = i / 4000
            x = 50 + 460 * s + 46 * math.sin(2 * math.pi * 3.2 * s) * (1 - .5 * s)
            y = 96 - 52 * math.cos(2 * math.pi * 3.2 * s) * (.55 + .45 * math.sin(math.pi * s)) + 34 * s * s
            pts.append((x * D, y * D, (2.2 + 3.2 * math.sin(math.pi * s) ** .6) * D))
        for i in range(800):                       # the underline swash
            s = i / 800
            pts.append(((70 + 450 * s) * D, (165 - 18 * math.sin(math.pi * s)) * D, (1.4 + 2.4 * math.sin(math.pi * s)) * D))
        alpha = bytearray(w * h); ink = hexrgb(PAL['ink'])
        per = len(pts) / 27
        for f in range(27):
            for x0, y0, r in pts[int(f * per):int((f + 1) * per)]:
                for yy in range(int(y0 - r - 1), int(y0 + r + 2)):
                    for xx in range(int(x0 - r - 1), int(x0 + r + 2)):
                        if 0 <= xx < w and 0 <= yy < h:
                            a = r + .5 - math.hypot(xx - x0, yy - y0)
                            if a > 0:
                                v = 255 if a >= 1 else round(255 * a)
                                if v > alpha[yy * w + xx]: alpha[yy * w + xx] = v
            rgba = bytearray(4 * w * h)
            rgba[0::4] = bytes([ink[0]]) * (w * h); rgba[1::4] = bytes([ink[1]]) * (w * h)
            rgba[2::4] = bytes([ink[2]]) * (w * h); rgba[3::4] = alpha
            write_png(fdir / f'{f:04d}.png', rgba, w, h)
    return {'stack': stack, 'angle': cut, 'flood': flood, 'detail': det, 'flourish': fdir}, meas

# ------------------------------------------------------------------ geometry per frame
def mat_mul(A, B):   # 2x3 affine composition A*B
    return (A[0] * B[0] + A[1] * B[3], A[0] * B[1] + A[1] * B[4], A[0] * B[2] + A[1] * B[5] + A[2],
            A[3] * B[0] + A[4] * B[3], A[3] * B[1] + A[4] * B[4], A[3] * B[2] + A[4] * B[5] + A[5])

def inverse(M):
    a, b, c, d, e, f = M; det = a * e - b * d
    return (e / det, -b / det, (b * f - c * e) / det, -d / det, a / det, (c * d - a * f) / det)

def apply(M, x, y): return M[0] * x + M[1] * y + M[2], M[3] * x + M[4] * y + M[5]

def frame_matrix(film, sprite, t, Wr, Hr, W):
    R = sprite.rig.affine(t)
    if sprite.rig.space == 'screen':
        k = Wr / W
        return mat_mul((k, 0, 0, 0, k, 0), R)
    cx, cy, Vh = film['camera'](t)
    k = Hr / Vh
    return mat_mul((k, 0, Wr / 2 - k * cx, 0, k, Hr / 2 - k * cy), R)

def max_scale(M):
    a, b, _, d, e, _ = M
    s = a * a + b * b + d * d + e * e; q = math.sqrt(max(0.0, (a * a + b * b - d * d - e * e) ** 2 + 4 * (a * d + b * e) ** 2))
    return math.sqrt((s + q) / 2)

# ------------------------------------------------------------------ one segment
def plan_segment(film, f0, f1, Wr, Hr, Wf):
    """What is visible in frames f0..f1-1, the native box of each sprite that can be seen, and its
    largest on-screen scale (render px per native px)."""
    n = f1 - f0
    ts = [plan.plan_time((f0 + i) / FPS) for i in range(n)]
    layers = []
    for s in film['sprites']:
        al = [max(0.0, min(1.0, s.alpha(t))) for t in ts]
        vis = [i for i in range(n) if al[i] > .002]
        if not vis: continue
        Ms = [frame_matrix(film, s, t, Wr, Hr, Wf) if al[i] > .002 else None for i, t in enumerate(ts)]
        rw, rh = s.rect[2:]
        bx0 = by0 = 1e18; bx1 = by1 = -1e18; smax = 0
        for i in vis:
            sc = max_scale(Ms[i])
            if sc < 1e-6: continue
            smax = max(smax, sc)
            Inv = inverse(Ms[i])
            for X, Y in ((-2, -2), (Wr + 2, -2), (-2, Hr + 2), (Wr + 2, Hr + 2)):
                u, v = apply(Inv, X, Y)
                bx0, by0, bx1, by1 = min(bx0, u), min(by0, v), max(bx1, u), max(by1, v)
        x0 = max(0, math.floor(bx0) - 2); y0 = max(0, math.floor(by0) - 2)
        x1 = min(rw, math.ceil(bx1) + 2); y1 = min(rh, math.ceil(by1) + 2)
        if x1 - x0 < 1 or y1 - y0 < 1 or smax == 0: continue
        layers.append(dict(s=s, al=al, Ms=Ms, box=[x0, y0, x1, y1], smax=smax))
    # sprites on one rig with one image size share crop and scale, so stacked layers resample alike
    groups = {}
    for L in layers:
        groups.setdefault((id(L['s'].rig), L['s'].rect[2:]), []).append(L)
    for g in groups.values():
        box = [min(L['box'][0] for L in g), min(L['box'][1] for L in g),
               max(L['box'][2] for L in g), max(L['box'][3] for L in g)]
        smax = max(L['smax'] for L in g)
        for L in g: L['box'], L['smax'] = box, smax
    for L in layers:
        x0, y0, x1, y1 = L['box']; cw, ch = x1 - x0, y1 - y0
        f = min(1.0, L['smax'])                    # never enlarge before the warp
        L['crop'] = (L['s'].rect[0] + x0, L['s'].rect[1] + y0, cw, ch)
        L['scaled'] = (max(1, round(cw * f)), max(1, round(ch * f)))
        if L['s'].src[0] == 'color':           # lavfi color wants even sizes
            L['scaled'] = tuple(max(2, v + v % 2) for v in L['scaled'])
    return layers

def prescale(layers, kinds, work, idx):
    """One FFmpeg call per segment: every still sprite cropped and lanczos-scaled to raw RGBA."""
    ins, outs, g = [], [], []
    for j, L in enumerate(layers):
        kind = L['s'].src[0]
        if kind in ('color', 'seq'): continue
        path = L['s'].src[1] if kind == 'file' else kinds[kind]
        (cx, cy, cw, ch), (sw, sh) = L['crop'], L['scaled']
        L['raw'] = work / f'seg{idx:03d}-{j:02d}.rgba'
        k = len(ins) // 2
        ins += ['-i', path]
        g.append(f'[{k}:v]crop={cw}:{ch}:{cx}:{cy},scale={sw}:{sh}:flags=lanczos,format=rgba[o{k}]')
        outs += ['-map', f'[o{k}]', '-frames:v', 1, '-f', 'rawvideo', L['raw']]
    if ins:
        run([*ins, '-filter_complex', ';'.join(g), *outs])

def frame_graph(layers, i, f, Wr, Hr, W, H, kinds):
    """Input args and filter graph for one frame: each visible sprite padded to a canvas at least the
    render size, warped by perspective (constant corners) and faded, then stacked on ink."""
    ins, chains, k = [], [], 0
    for L in layers:
        a = L['al'][i]
        if a <= .002: continue
        s = L['s']; kind = s.src[0]
        (cx, cy, cw, ch), (sw, sh) = L['crop'], L['scaled']
        if kind == 'color':
            ins += ['-f', 'lavfi', '-i', f'color=c=0x{s.src[1][1:]}:s={sw}x{sh}:r={FPS}']
            pre = f'[{k}:v]format=gbrap'
        elif kind == 'seq':
            first, count = s.src[3], s.src[2]
            ins += ['-i', kinds[s.src[1]] / f'{min(max(0, round(plan.plan_time(f / FPS) * FPS) - first), count - 1):04d}.png']
            pre = f'[{k}:v]crop={cw}:{ch}:{cx}:{cy},scale={sw}:{sh}:flags=lanczos,format=gbrap'
        else:
            ins += ['-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{sw}x{sh}', '-i', L['raw']]
            pre = f'[{k}:v]format=gbrap'
        # perspective clamps samples that fall outside its input, so every sprite gets a transparent
        # margin on all four sides (otherwise its edge pixels smear to infinity)
        m = 2
        CW, CH = max(sw, Wr) + 2 * m, max(sh, Hr) + 2 * m
        M = L['Ms'][i]; bx, by = L['box'][:2]
        pts = []
        for U, V in ((0, 0), (CW, 0), (0, CH), (CW, CH)):
            pts += apply(M, bx + (U - m) * cw / sw, by + (V - m) * ch / sh)
        persp = ':'.join(f'{nm}={v:.3f}' for nm, v in zip(('x0', 'y0', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3'), pts))
        padc = f'0x{s.src[1][1:]}@0' if kind == 'color' else 'black@0'   # no dark fringe on flat colour
        chain = (f'{pre},pad={CW}:{CH}:{m}:{m}:color={padc},perspective={persp}:sense=destination,'
                 f'crop={Wr}:{Hr}:0:0')
        if a < .999: chain += f',colorchannelmixer=aa={a:.4f}'
        chains.append(chain + f'[s{k}]'); k += 1
    ins += ['-f', 'lavfi', '-i', f'color=c=0x{PAL["ink"][1:]}:s={Wr}x{Hr}:r={FPS}']
    g = f'[{k}:v]format=gbrp[b0];' + ''.join(f'[b{j}][s{j}]overlay=format=gbrp[b{j + 1}];' for j in range(k))
    g = ''.join(c + ';' for c in chains) + g + f'[b{k}]scale={W}:{H}:flags=lanczos,format=rgb24[v]'
    return ins, g

def render_frame(args):
    ins, g = args
    r = sp.run([FF, '-v', 'error', *map(str, ins), '-filter_complex', g, '-map', '[v]', '-frames:v', '1',
                '-f', 'rawvideo', '-'], capture_output=True)
    if r.returncode: raise RuntimeError(r.stderr.decode()[-2000:])
    return r.stdout

def segments_for(film, Wr, Hr, W):
    """1 s segments (cut at the hit), halved while any sprite's scale changes by more than 2x."""
    cuts = sorted(set(list(range(0, HIT_FRAME, 30)) + [HIT_FRAME]))
    out = []
    def ratio(a, b):
        worst = 1.0
        for s in film['sprites']:
            sc = [max_scale(frame_matrix(film, s, plan.plan_time(t / FPS), Wr, Hr, W)) for t in range(a, b)
                  if s.alpha(plan.plan_time(t / FPS)) > .002]
            sc = [x for x in sc if x > 1e-4]
            if len(sc) > 1: worst = max(worst, max(sc) / min(sc))
        return worst
    def split(a, b):
        if b - a > 3 and ratio(a, b) > 2.0:
            m = (a + b) // 2; split(a, m); split(m, b)
        else: out.append((a, b))
    for a, b in zip(cuts, cuts[1:]): split(a, b)
    return out

# ------------------------------------------------------------------ the film
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--aspect', default='16x9', choices=list(plan.ASPECTS))
    ap.add_argument('--width', type=int, default=None, help='output width (height follows the aspect)')
    ap.add_argument('--music', default=None, help='40.000 s WAV; omitted = a silent AAC track')
    ap.add_argument('--kicker', default='a5', choices=['a5', 'a5-alt'])
    ap.add_argument('--out', required=True)
    ap.add_argument('--work', default=str(ROOT / 'test/scratch/film-a'))
    ap.add_argument('--resume', action='store_true', help='keep finished segments in --work')
    ap.add_argument('--jobs', type=int, default=os.cpu_count() or 2)
    a = ap.parse_args()
    Wf, Hf = plan.ASPECTS[a.aspect]
    W = a.width or Wf; H = round(W * Hf / Wf / 2) * 2
    Wr, Hr = W * SS, H * SS
    work = Path(a.work).resolve() / f'{a.aspect}-{W}'
    if work.exists() and not a.resume: shutil.rmtree(work)
    work.mkdir(parents=True, exist_ok=True)
    kinds, meas = prep(Path(a.work).resolve() / 'prep')
    print(f'stack vs note-master: {meas["stack_vs_master"]}; angle plate note bbox: {meas["angle_note_bbox"]}',
          flush=True)
    film = plan.build(a.aspect, a.kicker)
    segs = segments_for(film, Wr, Hr, Wf)
    files = []
    with ThreadPoolExecutor(a.jobs) as pool:
        for i, (f0, f1) in enumerate(segs):
            seg = work / f'seg{i:03d}.mkv'; files.append(seg)
            if seg.exists(): continue                      # --resume: finished segments are kept
            layers = plan_segment(film, f0, f1, Wr, Hr, Wf)
            prescale(layers, kinds, work, i)
            tmp = work / f'seg{i:03d}.tmp.mkv'
            enc = sp.Popen([FF, '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}',
                            '-r', str(FPS), '-i', '-', '-c:v', 'ffv1', str(tmp)], stdin=sp.PIPE)
            jobs = [frame_graph(layers, n, f0 + n, Wr, Hr, W, H, kinds) for n in range(f1 - f0)]
            for data in pool.map(render_frame, jobs):
                assert len(data) == W * H * 3
                enc.stdin.write(data)
            enc.stdin.close(); assert enc.wait() == 0
            tmp.rename(seg)
            for L in layers:
                if 'raw' in L: L['raw'].unlink()
            print(f'segment {i:03d} frames {f0}-{f1 - 1}: {len(layers)} sprites', flush=True)
    assert sum(f1 - f0 for f0, f1 in segs) == HIT_FRAME
    flash, card = work / 'flash.mkv', work / 'card.mkv'
    run(['-f', 'lavfi', '-i', f'color=c=0x{PAL["ivory"][1:]}:s={W}x{H}:r={FPS}', '-vf', 'format=gbrp',
         '-frames:v', 2, '-c:v', 'ffv1', flash])
    endcard = ROOT / f'marketing/kit/endcard/endcard-{Wf}x{Hf}.png'
    blank, live = endcard.with_name(endcard.stem + '-blank.png'), endcard.with_name(endcard.stem + '-live.png')
    if blank.exists() and live.exists():
        # The status chip blinks from STAGING to LIVE (as in film B): off 0.80-0.95, on, off 1.10-1.25, then LIVE.
        sc = f'scale={W}:{H}:flags=lanczos,format=gbrp'
        g = (f'[0:v]{sc}[c0];[1:v]{sc}[b];[2:v]{sc}[l];[b]split[b1][b2];'
             "[c0][b1]overlay=0:0:enable='between(t,0.80,0.95)'[c1];"
             "[c1][b2]overlay=0:0:enable='between(t,1.10,1.25)'[c2];"
             "[c2][l]overlay=0:0:enable='gte(t,1.25)'[v]")
        run(['-loop', 1, '-framerate', FPS, '-i', endcard, '-loop', 1, '-framerate', FPS, '-i', blank,
             '-loop', 1, '-framerate', FPS, '-i', live, '-filter_complex', g, '-map', '[v]',
             '-frames:v', NFRAMES - HIT_FRAME - 2, '-c:v', 'ffv1', card])
    else:
        run(['-loop', 1, '-framerate', FPS, '-i', endcard, '-vf', f'scale={W}:{H}:flags=lanczos,format=gbrp',
             '-frames:v', NFRAMES - HIT_FRAME - 2, '-c:v', 'ffv1', card])
    (work / 'list.txt').write_text(''.join(f"file '{p.name}'\n" for p in files + [flash, card]))
    audio = ['-i', a.music] if a.music else ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo']
    out = Path(a.out); out.parent.mkdir(parents=True, exist_ok=True)
    run(['-f', 'concat', '-safe', 0, '-i', work / 'list.txt', *audio, '-map', '0:v', '-map', '1:a',
         '-vf', f'fps={FPS},format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', 18,
         '-profile:v', 'high', '-x264-params', 'keyint=30:min-keyint=1:scenecut=0', '-frames:v', NFRAMES,
         '-c:a', 'aac', '-b:a', '256k', '-ar', 48000, '-ac', 2, '-t', f'{NFRAMES / FPS:.3f}',
         '-movflags', '+faststart', out])
    print('wrote', out, flush=True)

if __name__ == '__main__':
    main()
