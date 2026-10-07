#!/usr/bin/env python3
"""Measures a render of film A with ffprobe/ffmpeg and fails on any breach of the timing contract.

  python3 marketing/explainer/film-a/check.py artifacts/animatic-16x9.mp4 [--json out.json] [--silent]

Checks: H.264 yuv420p + AAC, 30 fps, 1200 frames, 40.000 s; the frame at 36.500 s (index 1095) and the
next are ivory, the one before is not, the end card holds from index 1097; moov before mdat (+faststart);
with --silent, the audio peak is below -80 dBFS. Python standard library + FFmpeg.
"""
import json, os, re, subprocess as sp, sys

FF, FP = os.environ.get('FFMPEG', 'ffmpeg'), os.environ.get('FFPROBE', 'ffprobe')
IVORY = (247, 245, 239)

def probe(path):
    return json.loads(sp.check_output([FP, '-v', 'error', '-count_frames', '-show_streams', '-show_format',
                                       '-of', 'json', path]))

def frame_means(path, w, h, idx):
    sel = '+'.join(f'eq(n\\,{i})' for i in idx)
    raw = sp.check_output([FF, '-v', 'error', '-i', path, '-vf', f'select={sel}', '-vsync', '0',
                           '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
    n = w * h * 3; out = []
    for k in range(len(idx)):
        f = raw[k * n:(k + 1) * n]
        out.append(tuple(round(sum(f[c::3]) / (w * h), 1) for c in range(3)))
    return out

def pts_times(path, first, last):
    out = sp.check_output([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
                           '-of', 'csv=p=0', path]).decode().split()
    return [float(x) for x in out[first:last + 1]], len(out)

def boxes(path):
    order, data = [], open(path, 'rb').read(1 << 20)
    i = 0
    while i + 8 <= len(data):
        size = int.from_bytes(data[i:i + 4], 'big'); name = data[i + 4:i + 8].decode('latin1')
        order.append(name)
        if size < 8 or name == 'mdat': break
        i += size
    return order

def main():
    path = sys.argv[1]; silent = '--silent' in sys.argv
    jout = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    p = probe(path)
    v = next(s for s in p['streams'] if s['codec_type'] == 'video')
    a = next((s for s in p['streams'] if s['codec_type'] == 'audio'), None)
    w, h = v['width'], v['height']
    times, nframes = pts_times(path, 1094, 1097)
    means = frame_means(path, w, h, [1094, 1095, 1096, 1097, 1199])
    r = dict(file=path, bytes=os.path.getsize(path), width=w, height=h, video_codec=v['codec_name'],
             profile=v.get('profile'), pix_fmt=v['pix_fmt'], r_frame_rate=v['r_frame_rate'],
             frames_counted=int(v['nb_read_frames']), frames_pts=nframes,
             video_duration=float(v['duration']), container_duration=float(p['format']['duration']),
             audio_codec=a and a['codec_name'], audio_rate=a and a['sample_rate'],
             audio_channels=a and a['channels'], audio_duration=a and float(a['duration']),
             pts_1094_1097=times, mean_rgb={'1094': means[0], '1095': means[1], '1096': means[2],
                                            '1097': means[3], '1199': means[4]},
             top_level_boxes=boxes(path))
    if a:
        vd = sp.run([FF, '-v', 'info', '-i', path, '-map', '0:a', '-af', 'volumedetect', '-f', 'null', '-'],
                    capture_output=True).stderr.decode()
        m = re.search(r'max_volume: (-?[\d.]+|-inf) dB', vd)
        r['audio_max_dB'] = m and m.group(1)
    near = lambda c, ref, tol: all(abs(x - y) <= tol for x, y in zip(c, ref))
    checks = {
        'h264 yuv420p': r['video_codec'] == 'h264' and r['pix_fmt'] == 'yuv420p',
        'aac': r['audio_codec'] == 'aac',
        '30 fps': r['r_frame_rate'] == '30/1',
        '1200 frames': r['frames_counted'] == 1200 and r['frames_pts'] == 1200,
        '40.000 s': abs(r['video_duration'] - 40) < 1e-3 and abs(r['container_duration'] - 40) < 0.03,
        'cut at 36.500 s': abs(times[1] - 36.5) < 1e-6,
        'flash frames 1095-1096 ivory': near(means[1], IVORY, 3) and near(means[2], IVORY, 3),
        'frame 1094 is not the flash': not near(means[0], IVORY, 12),
        'end card from 1097 to 1199': means[3] == means[4] or near(means[3], means[4], 1),
        'faststart (moov before mdat)': 'moov' in r['top_level_boxes'] and
            r['top_level_boxes'].index('moov') < r['top_level_boxes'].index('mdat'),
    }
    if silent:
        checks['silent audio'] = r.get('audio_max_dB') in ('-inf',) or float(r['audio_max_dB']) < -80
    r['checks'] = checks
    print(json.dumps(r, indent=1))
    if jout: open(jout, 'w').write(json.dumps(r, indent=1) + '\n')
    bad = [k for k, ok in checks.items() if not ok]
    if bad: sys.exit('FAILED: ' + ', '.join(bad))
    print('all checks passed')

if __name__ == '__main__':
    main()
