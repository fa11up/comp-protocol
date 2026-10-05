# The Note: source

Procedural canvas drawing, no generative model. Drawn by the swarm's plates step (job `6f519658`,
seat 660), then revised by us:

- **Left rosette** is real guilloché now (rotated lathe curves with petal outlines) instead of a soft
  moiré disc, so it reads as a flower at post size.
- **The seal** has its own place on the right instead of overlapping a second rosette, and carries the
  pixel I mark at 12 px per mark pixel.
- **Lettering**: the site's `imdUSD` lockup in the banner, `1` in the four corners, green serial
  numbers. Set `globalThis.NO_LETTERING = true` before `note.js` runs for the bare plate.
- **Blink frames** (`blink-075` … `blink-000`): the portrait with its eyes at 75/50/25/0 percent open,
  for the video's blink (storyboard section 5c). `setEyes(open)` in `portrait.js` builds the lids.
- **`note-master.png`**: the flat note at its native 3264x1400, the sharpest base for a push-in.

The portrait oval's size and position are unchanged, so the storyboard's geometry still holds.

Rebuild: `node marketing/the-note/render.mjs` (writes `marketing/kit/plates/`). `run.sh` is the
original google-chrome route.
