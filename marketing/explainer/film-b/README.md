# Film B render delivery

This delivery uses the accepted 1920×1080 engraved plates in `keyframes/`.
All six picture shots use the storyboard's code fallback (the accepted still
plus the specified camera move/dissolve), rather than an image-to-video clip.
This was the safe selection after clip review: it cannot introduce the
prohibited letters, numerals, glyph-like dial marks, faces, objects, or style
drift. K5 and K6 are consequently locked off as required.

| Shot | Picture source | Reason |
|---|---|---|
| K1 bank | Code fallback, 1.00→1.06 push | Preserves the empty cartouche and bank engraving. |
| K2 board | Code fallback, 1.00→1.05 push | Preserves blank coin, fixed figures, and no readable faces. |
| K3 dissolve | Code fallback, 1.00→1.03 push | Preserves the shared board/panel perspective. |
| K4 swarm | Code fallback, 1.08→1.00 pull | Preserves non-glyph dial faces and guilloché repetition. |
| K5 converge | Code fallback, locked plate plus 1.00→1.08 code push | Keeps the real screen fixed for cut typography. |
| K6 press | Code fallback, locked plate plus code assembly/push | Keeps the real sheet fixed for the note corner pin. |

No generated clips were retained, so there is no model, seed, or generation
setting to report. The deliberate limitation is that the dial needles do not
animate; the timing, cut typography, and print assembly carry those beats.

K5 typography uses the measured field `x=589–1370`, `y=241–767`, with a
40-pixel horizontal inset and a visible-screen baseline of y=470; the push
centres at `(980, 504)`. K6's measured sheet bounds
were `(606,246)`, `(1749,246)`, `(650,968)`, `(1603,968)` (TL/TR/BL/BR). The
2.33:1 note is perspective-pinned inside that sheet at `(680,360)`,
`(1680,360)`, `(715,785)`, `(1595,785)`, leaving paper margin on all sides.

## Render contract

- Music: `marketing/explainer/anthem/explainer-anthem.wav`, used from sample
  zero without gain, fade, or retiming; 48 kHz AAC in the deliverables.
- Video: H.264 High, yuv420p, 30 fps, AAC 48 kHz stereo, `+faststart`.
- Timing: 40.000 seconds / 1200 video frames. The ivory HIT is frames 1095
  and 1096 at 36.500 and 36.533 seconds; end card begins at 36.567 seconds.
- Encoding: libx264 medium, CRF 24; native 1920×1080 source plates.

Measured with `ffprobe -count_frames`:

| File | Video / audio | Dimensions | Frames | Measured duration | HIT check |
|---|---|---:|---:|---:|---|
| `artifacts/film-b-16x9.mp4` | H.264 High yuv420p / AAC-LC 48 kHz stereo | 1920×1080 | 1200 | 40.000000 s | frame 1095 = 36.500000, frames 1095–1096 ivory |
| `artifacts/film-b-1x1.mp4` | H.264 High yuv420p / AAC-LC 48 kHz stereo | 1080×1080 | 1200 | 40.000000 s | frame 1095 = 36.500000, frames 1095–1096 ivory |
| `artifacts/film-b-9x16.mp4` | H.264 High yuv420p / AAC-LC 48 kHz stereo | 1080×1920 | 1200 | 40.000000 s | frame 1095 = 36.500000, frames 1095–1096 ivory |

The poster is `artifacts/film-b-poster-16x9.png`, a 1920×1080 extraction of
frame 999 (33.300 seconds), after the final `serials` assembly ramp completes.
