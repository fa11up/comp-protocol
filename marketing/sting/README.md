# imdUSD launch stings

Two original instrumental eyecatches for the engraved banknote push-in and ivory
end card in [the brief](../kit/BRIEF.md). A is bright and buoyant; B is warmer,
slower, and more swung. Both use original melodies and synthesized instruments,
with no vocals, spoken words, recorded samples, soundfonts, or song references.

| Take | WAV master | MP3 preview | Tempo | Key / final chord |
| --- | --- | --- | --- | --- |
| A | [sting-a.wav](../../artifacts/sting-a.wav) | [sting-a.mp3](../../artifacts/sting-a.mp3) | 110.769231 BPM | D major / D6/9 |
| B | [sting-b.wav](../../artifacts/sting-b.wav) | [sting-b.mp3](../../artifacts/sting-b.mp3) | 73.846154 BPM | A-flat major / Ab6/9 |

Both WAVs are exactly **10.000000 s**, **480,000 frames**, **48,000 Hz**, **stereo**,
**16-bit little-endian PCM** in RIFF/WAVE (1,920,044 bytes each). Both MP3s are
**320 kbps CBR**, **48,000 Hz stereo**, 402,284 bytes each, encoded from their
respective WAVs. FFmpeg decodes each MP3 to exactly 480,000 stereo frames / 10 s.

Instrumentation: soft FM electric piano with a Rhodes-like tine attack, bright
glass chimes, round sine bass, synthesized kick/rim-snare and filtered-noise hats,
and an original dry rubber/wood stamp made from a pitched knock and noise crack.
Subtle pitch drift, tremolo, soft saturation, and a short stereo room add warmth.
A uses a higher bell register and light syncopated chord replies; B uses lower
chimes, closer voicings, and more relaxed swung eighths.

The gentle build occupies 0–6.5 s: three bars in A, two in B. A moves through
Gmaj9, Em9 with an added 11th, and A13 into D6/9. B moves through Fm9, Dbmaj9,
Bbm9, and Eb13 into Ab6/9. At **6.500 s**, the final tonic chord, bass, chime and
stamp land together. From there, only sustain, releases, and room decay remain;
no new notes or drum hits are scheduled. The tail reaches silence before 10 s.

| Measured check | A | B |
| --- | --- | --- |
| Stamp onset, verified at 1 ms resolution | 6.500 s (±1 ms) | 6.500 s (±1 ms) |
| WAV sample peak | −1.8003 dBFS | −1.8003 dBFS |
| Decoded MP3 sample peak | −1.7999 dBFS | −1.7934 dBFS |
| True peak, FFmpeg EBU R128, WAV and MP3 | −1.8 dBTP | −1.8 dBTP |
| Integrated loudness, WAV | −14.9 LUFS | −14.6 LUFS |
| Last nonzero WAV frame | 9.665146 s | 9.676083 s |
| Final 100 ms, WAV and decoded MP3 | Digital silence | Digital silence |
| Saturated PCM samples, WAV and decoded MP3 | 0 | 0 |

[measurements.json](measurements.json) records independent byte/signal checks.
[audio-review.json](audio-review.json) records the audio tool's review of both
final WAVs: instrumental, warm/playful, resolved endings, no detected vocals or
unintended clicks/distortion. Earlier generated drafts were rejected for content
and timing; no audio from those drafts appears in these deliverables.

Limitations: these are synthesized Rhodes-style instruments, not recordings of
an acoustic instrument. Automated listening and signal analysis are not human
creative approval; audition each against the final picture on headphones and a
phone speaker when selecting the launch take. MP3 players that ignore gapless
delay/padding metadata can display or play extra encoder padding; use the WAV
master for precise video sync.

The complete original score and instrument synthesis are in [render.py](render.py).
Rebuild with `python3 marketing/sting/render.py` from the repository root, or pass
an output directory. This uses only Python's standard library and the installed
FFmpeg with libmp3lame; no downloads or new dependencies are needed. The delivered
audio files are already rendered under `artifacts/` and remain untracked for the
artifact uploader. Existing artwork and project build configuration are unchanged.
