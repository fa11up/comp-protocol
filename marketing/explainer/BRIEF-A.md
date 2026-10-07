# imdUSD explainer A: "The note is the diagram"

A 40.000 s piece that explains how imdUSD works. The engraved banknote from the launch art is the
ONLY set: every element on it is one mechanism of the protocol, and the film visits them one at a time.
No voiceover. Four captions carry the words. The last 3.5 s is the launch end card.

Read `marketing/kit/BRIEF.md` first for the palette, the rules and the idea of the note. This brief adds
what the explainer needs. `marketing/explainer/layers/` holds the note taken apart; `layers/geometry.json`
holds every coordinate so nothing needs re-deriving from `marketing/the-note/note.js`.

## What imdUSD is, in the four sentences the film tells

1. **Lock IMD. Borrow dollars.** A borrower deposits staked IMD (sIMD) into the vault and borrows imdUSD
   against it, always more collateral than debt.
2. **The price is a question. A panel of agents answers it.** The dollar value of the collateral is not
   read from an exchange. A panel of IdentityMD agents answers one fixed question about the IMD price,
   the answer is signed, and anyone may submit it on chain. No key can set a price.
3. **Every note redeems for a dollar of IMD.** Anyone can burn one imdUSD and receive one dollar of sIMD
   (less a fee). That floor is what holds the peg.
4. **Fall short, and the swarm collects.** If a position's collateral falls short, keepers mark it and
   liquidate it, and are paid from the liquidation bonus.

Kicker on the end card build-up (one of): `Minted by agents. Redeemable by anyone.` or
`A dollar with a panel behind it.` Caption plates for all of these are in `layers/caption-*.png`.

## The map: element -> mechanism

| Beat | Note element (layer) | What it stands for | Motion idea |
|---|---|---|---|
| 1 | the portrait oval (`portrait.png`) | the vault | an engraved IMD coin (`coin-imd.png`) slides into the oval and becomes sIMD (`coin-simd.png`); the note's paper prints out from under it |
| 2 | the guilloché rosette (`rosette.png`) | the oracle panel | the rosette's lathe lines are the panel: they spin, each line is one agent's answer, they converge to a single figure at the centre, a signature flourish, and the figure travels along the serial strip (`serials-empty.png`, typed by the cut) onto the note |
| 3 | the red seal (`seal.png`, `seal-stamp.png`) | redemption | the seal stamps down on the note with its rim lettering REDEEMABLE FOR ONE DOLLAR OF IMD / BACKED BY THE SWARM, then settles back into its place on the note |
| 4 | the corner denominations (`corners.png`) | the peg, and what guards it | a second note (the perspective plate `marketing/kit/plates/note-angle-16x9.png`) tilts and slides below the line; border ink floods it; it is pulled off frame; the remaining notes straighten |
| end | the launch cut | the brand | the existing push into the portrait, the blink, the hit, the end card |

The note reassembles pixel-perfectly from the layers in `geometry.json`'s `stackOrder`
(`stackEqualsMaster.differingPixels` is 0), so the film may take the note apart and put it back together
exactly.

## Timing (fixed, shared with the music)

40.000 s at 30 fps. These times are the contract between the music, the storyboard and the cut.

| Time | What |
|---|---|
| 0.000 – 3.000 | cold open: the whole note on ink, still; no caption |
| 3.000 – 11.000 | beat 1 (vault), caption a1 |
| 11.000 – 20.000 | beat 2 (oracle), caption a2 — the longest beat, it is the one people do not know |
| 20.000 – 28.000 | beat 3 (redemption), caption a3 |
| 28.000 – 33.500 | beat 4 (liquidation), caption a4 |
| 33.500 – 36.500 | the push into the portrait with the blink (the launch cut's move, compressed), kicker caption |
| 36.500 | HIT: two-frame ivory flash, hard cut to the end card |
| 36.500 – 40.000 | end card (`marketing/kit/endcard/`), music tails out, silent by 39.900 |

Captions sit in the lower third over the ink ground (`caption-*-ivory.png`) or over the paper
(`caption-*-ink.png`), never over the portrait's face. Each caption is on screen for at least 3.0 s and
fades, never pops.

## Music brief A: "The Treasury"

An anthem for a treasury run by frogs: dignified, with a wink. Regal and engraved, then modern under it.

- Instruments: harpsichord or plucked strings and pizzicato for the lathe-line feel; a ticking
  clockwork percussion (the panel counting) through beat 2; timpani and a brass cadence for the hit;
  a polite, modern low end (808 sub, claps) that enters at beat 1 and never turns it into club music.
- Tempo around 120 BPM, chosen so that 36.500 s lands on a downbeat. State the tempo in the README.
- Form follows the table above: a clear change of texture at 3.0, 11.0, 20.0 and 28.0 (an accent the
  cut can land on: a cymbal, a chord, a drop-out), a build from 33.5, the HIT at 36.500 (brass cadence
  + a stamp + a cash-register ka-ching, resolving to a major chord: money is sound), then a tail that
  is fully silent by 39.900.
- Nothing stays the same for more than 4 s. The plainness of a looped bed is the failure mode.
- Instrumental only. No vocals, no spoken words, no samples of existing recordings, do not imitate any
  specific song or composer.
- Two takes, `anthem-a.wav` and `anthem-b.wav`, exactly 40.000 s, 48 kHz 16-bit stereo, peaks at or
  below -1 dBFS, plus 320 kbps MP3s. The README gives tempo, key, instrumentation, the MEASURED times of
  the section changes and the hit, and any limitation.

## Formats

16:9 1920x1080, 1:1 1080x1080, 9:16 1080x1920 (end cards exist for all three). The note is 2.33:1, so
the square and the vertical cuts frame tighter on the element in play rather than showing the whole
note; the whole note appears only in the cold open and the reassembly.

## Rules

- We letter, nothing else does: every word on screen comes from `layers/caption-*.png` or from the
  lettered layers. If the cut needs text that does not exist as a plate (for example the serial strip
  typing a figure), it uses the same monospace at the same weight as the plates, in the palette.
- No parameter values, no percentages, no addresses, no network names. The protocol's numbers are not
  final and the film must not age.
- Palette only (`geometry.json.palette`). No gradients beyond paper and engraving.
- No generative re-rendering of the engraving: the layers are moved, masked, scaled and composited,
  never redrawn by a model. Motion is code (ffmpeg, Python, or a browser canvas) and is reproducible.
- The portrait is dignified. The blink is the one facial motion.
- Clearly fictional: the note copies no real banknote.
