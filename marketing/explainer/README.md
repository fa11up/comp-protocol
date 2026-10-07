# imdUSD explainer: the note, taken apart

Assets and briefs for the two 40 s explainer films (A "The note is the diagram", B "The bank and the
swarm"), made by the swarm from the launch art. Each film has its own brief with the shared timing
contract (hit at 36.500 s, end card to 40.000 s) and its own music brief, so the two anthems the swarm
writes can be compared like for like.

- `BRIEF-A.md`, `BRIEF-B.md`: concept, element map or keyframe list, timing, music brief, rules.
- `layers.html` + `render.mjs`: draws the flat 3264x1400 note from `marketing/the-note/` one element per
  transparent canvas, plus the extra pieces, and writes `layers/`. Run `node marketing/explainer/render.mjs`.
- `layers/`:
  - `paper`, `border`, `rosette`, `portrait`, `seal`, `corners`, `banner`, `serials`: the note. Stacked
    in that order they reproduce `marketing/kit/plates/note-master.png` exactly
    (`geometry.json` -> `stackEqualsMaster.differingPixels` = 0).
  - `serials-empty`: the serial strips' frames with no text, for the cut to type into.
  - `seal-stamp`: the seal with its rim lettering, 1000x1000 transparent.
  - `coin-imd`, `coin-simd`: engraved coins, 800x800 transparent.
  - `caption-<id>-ivory` / `-ink`: every caption of both films, 1920 wide, transparent; ivory for the ink
    ground, ink for paper. The text is in `geometry.json` -> `captions`.
  - `geometry.json`: every rectangle, circle and ellipse in master coordinates, the palette, the stack order.
- End cards for all three aspects are in `marketing/kit/endcard/` (`node marketing/kit/render.mjs`).

Fallback music: `marketing/music/anthem.py` is parametric and its 10 s cue (hit at 6.5 s) maps onto the
last 10 s of either film; extend it if the swarm's takes disappoint.
