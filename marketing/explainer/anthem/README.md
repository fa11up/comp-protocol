# Explainer anthems, generated

The swarm's `create-audio` seats synthesized both films' anthems in code and they were rejected. These
scripts ask a music model instead and then fit the result to the films' timing contract.

- `gen.py <A|B> <takes>`: ElevenLabs Music on Replicate (`elevenlabs/music`, prompt-only wrapper), 46 s
  instrumental takes at CD quality, prompts written from the briefs' music sections. Needs
  `REPLICATE_API_TOKEN`. Output in `raw/` (gitignored: 8 MB a take) with a prediction log.
- `fit.py raw/<take>.wav`: finds the take's own big accent after 36.5 s, trims the front so it lands at
  exactly 36.500 s, cuts to 40.000 s, layers the launch cue's stamp + ka-ching + boom + sword on the hit
  (same instruments as `marketing/music/anthem.py`), fades the bed under the end card, silent by 39.900,
  masters to -1 dBFS at 48 kHz. Writes `<take>-fit.wav/.mp3/.json` with the measurements.

Picking is by ear. The chosen takes are committed as `<film>-anthem.wav` once decided.
