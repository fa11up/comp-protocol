# imdUSD launch cut

Delivered media (repository-root paths):

| File | Dimensions | Duration / frame |
|---|---|---|
| `artifacts/launch-16x9.mp4` | 1920 × 1080 | 10.000 s, 300 frames at 30 fps |
| `artifacts/launch-1x1.mp4` | 1080 × 1080 | 10.000 s, 300 frames at 30 fps |
| `artifacts/poster-16x9.png` | 1920 × 1080 | decoded video frame 90, 3.000 s |
| `artifacts/poster-1x1.png` | 1080 × 1080 | decoded video frame 90, 3.000 s |

Both MP4s use H.264 High, yuv420p, AAC-LC at 256 kb/s, 48 kHz stereo, and faststart. The audio is `marketing/music/imdusd-anthem.wav`, used from time zero without gain adjustment, normalization, fades, or timing changes. The supplied hit is at 6.500 s; the preceding sword scrape is retained.

The native 3264 × 1400 lettered `note-master.png` supplies the surround. The wide composite is 8320 × 4680: master scale 2.166666667, rounded surround 7072 × 3033, oval crop 1640 × 2000 resampled to 1642 × 2002 at (3339,1478). The square composite is 8028 × 8028: master scale 2.164411765, rounded surround 7065 × 3030, native 1640 × 2000 oval at (3194,3153). Thus the inlay is approximately 2.1645 times the oval in the native note, rather than 4.33 times an already reduced wide plate. A feathered elliptical mask excludes the portrait-detail background corners.

The camera follows storyboard section 4 with 2× output supersampling, and its Sobel-masked diagonal shimmer. The provided blink plates are linearly interpolated by section 5's k(T), inside the composite eye band before the camera transform. No generated or simulated lid is substituted. Closure starts at 5.800 s, is complete over 5.920–5.960 s, and reopens by 6.120 s. At 30 fps the completely closed sample is frame 178, 5.933333 s.

The measured cut in both finished files is frame 195 at exactly 6.500000 s (ffprobe presentation timestamp). Frames 195 and 196 are palette ivory (#F7F5EF). The supplied end cards enter unchanged at frame 197, 6.566667 s, and hold through frame 299 to 10.000 s. Only the required video compression and pixel-format conversion affect their bytes.

## Reproduction and checks

From the repository root, using Python 3 standard library and FFmpeg/ffprobe with libx264:

```
python3 marketing/launch/render.py
python3 marketing/launch/check.py
```

No downloaded packages or network access are needed. Rendering intermediates go under `test/scratch/launch/`; the four named deliverables are left untracked for the uploader. `verification.json` records the measured stream properties, cut timestamps from ffprobe, decoded flash colors, file sizes, MP4 box order, and exact poster/frame equality. The checker rejects a wrong codec, frame count, duration, cut, flash, poster, or size limit.

## Measured results

Both outputs passed `check.py`: 300 decoded frames, 30 fps, video/audio/container durations of 10.000000 s, required dimensions and codecs, and `moov` before `mdat`. Frames 195–196 decode to mean RGB (247,245,240); the end-card first frame measures 6.566667 s. The WAV-to-AAC correlation over 6.25–6.75 s is 0.993048 with zero-sample offset in each file. Both PNG posters exactly match decoded frame 90. File sizes are 20,535,558 bytes (wide MP4) and 12,622,918 bytes (square MP4), each below 64 MiB; the complete delivery is below 128 MiB. Contact sheets were visually inspected for the native-master composite, push, closed/reopening eyes, flash, and end card in both aspects.

## Limitations

The 30 fps grid cannot contain a frame timestamp at precisely 5.920 s; the continuous blink schedule is sampled at frame timestamps, yielding its fully closed frame at 5.933333 s. Intermediate eyelid positions are crossfades between the supplied quarter-open drawings. The storyboard's integer-coordinate zoompan can introduce minor subpixel stepping, and fine engraving may shimmer during scaling. H.264/AAC are lossy; ivory can differ slightly after yuv420p conversion and AAC may have decoder padding beyond the 10-second presentation timeline. Visual inspection uses decoded stills/contact sheets; no subjective audio audition is claimed.
