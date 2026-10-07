# Explainer render notes (for the create-video jobs)

Measured on the accepted keyframes of film B (job 39fa93ee), 1920x1080, by thresholding the ivory:

- **K5 `k5-converge.png`, the empty screen**: ivory field x 589–1370, y 241–767 (the pipeline's stand-in
  constant `SCREEN = (660, 280, 600, 360)` is wrong for the real frame; type inside the measured field
  with the same 40 px inset, and centre the push on (980, 504)).
- **K6 `k6-press.png`, the blank sheet**: a tilted quadrilateral, not a flat rectangle. Ivory extent per
  row: y 246 -> x 606–1749; y 607 -> x 601–1697; y 968 -> x 650–1603; bounding box x 600–1749,
  y 231–983. Corner-pin the assembled note onto the sheet (ffmpeg `perspective`, `sense=destination`)
  using corners measured on the real image rather than the flat `NOTE_XY` overlay; keep the note's
  2.33:1 aspect and leave a paper margin on every side.

Music: `marketing/explainer/anthem/explainer-anthem.wav` is the current pick (ElevenLabs take A-2, fitted:
40.000 s, hit at 36.500, silent by 39.900, -1 dBFS). Both films use it until a second choice is made; it
is one file to swap.

Film A decisions taken for the render (storyboard §9): the end card is used unchanged, chip included;
kicker `a5`; caption durations count their fades; the kicker starts in beat 4 as planned.
