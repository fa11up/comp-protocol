# imdUSD explainer B: "The bank and the swarm"

A 40.000 s piece in the engraving style of the launch note (`marketing/kit/BRIEF.md`): a bank deciding
what a dollar is worth dissolves, line by line, into a wall of agent panels answering one fixed
question, and the signed answer prints the note. No voiceover. Four captions. The last 3.5 s is the
launch end card.

It answers the question people actually ask about a stablecoin: who decides what the dollar is worth.
Here nobody does. A panel of IdentityMD agents answers one fixed question about the IMD price, the
answer is signed, anyone may submit it on chain, and every note redeems for a dollar of IMD.

Captions (plates in `marketing/explainer/layers/caption-b*.png`):

1. `Who decides what a dollar is worth?`
2. `Here, a panel of agents answers one fixed question.`
3. `The answer is signed. Anyone may submit it.`
4. `Every note redeems for a dollar of IMD.`

## The six keyframes (the image step)

Still images in the note's engraving register: ivory paper `#F7F5EF`, ink `#16202E` linework, engraved
green `#2F5D50` for secondary pattern and for the glowing traces on instruments, oxblood `#8C2F2F` only
for one seal or one lamp per frame, hairline `#D8D3C7` for faint rules. Fine intaglio hatching and
cross-hatching, no flat colour, no gradients, no photographic texture. Every frame 1920x1080 and
composed so a centre crop to 1080x1080 still holds the subject.

| # | File | Scene | Notes |
|---|---|---|---|
| K1 | `k1-bank.png` | a classical bank façade: columns, a pediment, steps, a vault door glimpsed inside | monumental, symmetrical, empty of people; an EMPTY cartouche on the pediment where a name would be |
| K2 | `k2-board.png` | a long boardroom table, figures in suits seen from behind, one standing at the head holding up a single coin | no faces, no text on anything, the coin blank |
| K3 | `k3-dissolve.png` | the same boardroom half-transformed: the right half of the frame has become a wall of engraved instrument panels (dials, meters, small oscilloscope screens with green traces), the left half is still the table and the figures | the transition frame; the two halves share one perspective |
| K4 | `k4-swarm.png` | the full wall of agent panels, floor to ceiling, hundreds of small engraved instruments, a few screens with a single green trace | the reference image is the note's guilloché: lathe-like repetition, not sci-fi |
| K5 | `k5-converge.png` | close on the wall: many dials, all needles turning to point at the same mark; one screen in the centre is an EMPTY framed rectangle | the empty screen is where the cut types the question and the answer |
| K6 | `k6-press.png` | an engraved intaglio printing slot, a sheet of blank ivory paper emerging from it at a slight angle, the paper EMPTY | the cut composites the real note from `marketing/explainer/layers/` onto that sheet |

Plus `sheet.png`, all six side by side. HARD RULES: no legible text, letters or numerals anywhere (the
cut letters everything); no real bank, logo or currency; no faces that read as real people; only the
five palette colours. Regenerate any frame that breaks a rule.

## Timing (fixed, shared with the music)

40.000 s at 30 fps.

| Time | What |
|---|---|
| 0.000 – 4.000 | ivory card, caption b1 types in (monospace, one character every 40 ms), holds |
| 4.000 – 14.000 | the bank: K1 with a slow push, dissolve to K2; the coin is raised |
| 14.000 – 24.000 | the dissolve: K2 -> K3 -> K4, the boardroom becomes the wall, caption b2 |
| 24.000 – 31.000 | K5: needles converge; the empty screen types a short question and one figure, a signature flourish; caption b3 |
| 31.000 – 36.500 | K6: the real note assembles on the blank sheet from the layers (paper, border, rosette, portrait, seal, corners, banner, serials in that order), caption b4; a push toward the portrait |
| 36.500 | HIT: two-frame ivory flash, hard cut to the end card |
| 36.500 – 40.000 | end card (`marketing/kit/endcard/`), music tails out, silent by 39.900 |

Motion between keyframes is image-to-video (5–10 s clips from each keyframe, slow camera moves, no
new objects, the style held) or, where a model cannot hold the engraving, a code-driven push and
cross-dissolve. The note assembly at 31.0 s is code only, from the layers, never generated.

## Music brief B: "The Swarm"

Cinematic electronic. The institution, then the machine, then one voice.

- 0–4 s: hollow and institutional. A single sustained piano or organ chord in a marble hall, a long
  reverb, a slow ticking clock. 4–14 s: stays sparse and heavy, a low pulse under the bank.
- 14–24 s: the machine arrives with the dissolve: arpeggiated synths, data blips, a sidechained pad,
  an 808 sub, momentum building. 24–31 s: many small plucked or bell voices in polyrhythm (the panel),
  resolving into ONE sustained note at about 29 s (the agreement), then a riser.
- 31–36.5 s: the print: a steady mechanical pulse, the riser continues, a gap in the last eighth before
  the hit. HIT at 36.500: brass braam + sub boom + a stamp. 36.5–40: the chord lifts from minor to
  major under the end card and is fully silent by 39.900.
- Tempo around 140 BPM with a half-time feel, chosen so that 36.500 s lands on a downbeat. State it.
- Nothing stays the same for more than 4 s. Instrumental only. No vocals, no spoken words, no samples
  of existing recordings, do not imitate any specific song or composer.
- Two takes, `anthem-a.wav` and `anthem-b.wav`, exactly 40.000 s, 48 kHz 16-bit stereo, peaks at or
  below -1 dBFS, plus 320 kbps MP3s. README: tempo, key, instrumentation, the MEASURED section-change
  and hit times, and any limitation.

## Formats and rules

16:9 1920x1080, 1:1 1080x1080 (centre crop of the keyframes), 9:16 1080x1920 (the keyframes
letterboxed on ink with the caption below). Captions in the lower third, at least 3.0 s each, fading.

- We letter, nothing else does. Every word comes from `layers/caption-*.png` or is typed by the cut in
  the same monospace. Image models produce no text.
- No parameter values, percentages, addresses or network names.
- Palette only. The engraving is never re-rendered by a model once it is the note: the note itself is
  always composited from the layers.
- Clearly fictional. No real bank, currency or person.
