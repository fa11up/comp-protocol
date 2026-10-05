# imdUSD launch art: "The Note"

imdUSD is a dollar stablecoin on the IdentityMD agent swarm. The website (imdusd.com) is going public
and we want one striking image, and later a short loop, to announce it. Not an explainer: a piece of
marketing that looks like it belongs in the IMD meme world and still looks like us.

## The idea

**A banknote from the swarm.** One imdUSD note, face side, as if engraved and printed by a treasury:
ivory paper, fine intaglio linework, guilloché rosettes, an ornate border, a treasury seal. Where a
president's portrait would be, an oval holds **Pepe the Frog, rendered as a banknote engraving**:
fine line hatching and cross-hatching, no flat colour, the way portraits on old notes are cut.

His likeness comes from the IMD meme vault (`refs/`): the 1990s anime-cel Pepe. Calm, three-quarter
view, heavy-lidded eyes, the faint knowing smile. Dignified, like a founding father, but unmistakably
Pepe. `refs/ref-pepe-medallion.png` is the closest existing take (a Pepe portrait in a gold
medallion); the others give the character and the mood.

## Palette (exact)

| Use | Name | Hex |
|---|---|---|
| Paper | ivory | `#F7F5EF` |
| Engraving, main linework | ink | `#16202E` |
| Secondary lathe pattern, undertint | engraved green | `#2F5D50` |
| Treasury seal | oxblood | `#8C2F2F` |
| Fine rules, faint undertint | hairline | `#D8D3C7` |

Nothing else: no gold, no neon, no gradients beyond what engraving and paper texture give. The note can
sit on dark ink `#16202E` or on ivory for the hero shots.

## Hard rules

- **No legible text, letters or numerals anywhere.** Image models garble lettering, and we letter the
  note ourselves afterwards at full resolution. Leave these areas present but EMPTY, as blank
  ornamental frames: a banner across the top, four corner cartouches (where denominations go), a
  serial-number strip, and the centre of the seal.
- **Clearly fictional.** Do not copy any real banknote's layout, portrait, seal or wording. An
  oversized frog portrait and the palette above keep it a parody, not a counterfeit.
- **Our logo is in `logo/`** (the pixel letter I, on a 16 px grid). If a design element calls for a
  mark, use that drawing exactly, or leave the space empty for us. Do not invent a logo.
- Pepe's face must read at thumbnail size: a clear oval, strong silhouette, eyes visible.

## What we add afterwards (do not do this)

The words "imdUSD", the denomination "1", serial numbers, the URL and the staging chip are added by us
in post. `endcard/` holds the finished end cards for the video.

## Files in this kit

- `refs/`: style references from the IMD meme vault (memedepot.com/d/imd-meme-vault).
- `logo/`: the mark as SVG and 1024 px PNG, on ivory, on ink and transparent.
- `endcard/`: the video's closing card, 1920x1080 and 1080x1080.
- `render.mjs`: regenerates `logo/*.png` and `endcard/*` from the site's mark and palette.
