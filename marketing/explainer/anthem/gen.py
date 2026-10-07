#!/usr/bin/env python3
"""Generate anthem takes for the explainer films with ElevenLabs Music on Replicate.

The swarm's create-audio seats synthesized their takes in code; this asks a music model instead. The
Replicate wrapper takes only a prompt, a length and an instrumental flag (no composition plan), so the
cue sheet is written into the prompt and the exact hit alignment is done afterwards by fit.py.

    REPLICATE_API_TOKEN=... python3 marketing/explainer/anthem/gen.py A 2    # film A, two takes
    REPLICATE_API_TOKEN=... python3 marketing/explainer/anthem/gen.py B 2

Writes marketing/explainer/anthem/raw/<film>-<n>.wav (44.1 kHz) and a prediction log beside it.
"""
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
RAW = HERE / "raw"
MODEL = "elevenlabs/music"
LENGTH_MS = 46000  # longer than the 40.000 s film so fit.py can slide the hit onto 36.500 and trim

# The prompts follow BRIEF-A.md / BRIEF-B.md "Music brief". The model has no clock, so the structure is
# described in order and in proportions; fit.py finds the real downbeat and aligns it.
PROMPTS = {
    "A": (
        "Instrumental, 46 seconds, around 120 BPM, in a major key. A regal anthem for a treasury, "
        "engraved and dignified with a wink: harpsichord and plucked strings, pizzicato, a ticking "
        "clockwork percussion, timpani, and a polite modern low end (a soft 808 sub and finger-snap "
        "claps) that never turns it into club music. Structure: a brief stately opening on harpsichord "
        "alone; the pulse and low end enter; a middle section where clockwork ticking and pizzicato "
        "count under sustained strings; a return of the theme with brass; a short rising build with a "
        "snare roll; then ONE decisive brass cadence hit, like a stamp landing on a banknote, resolving "
        "to a bright major chord that rings out and decays to silence. Clear changes of texture every "
        "few seconds, nothing loops unchanged. Cinematic, clean, mastered, no vocals."
    ),
    "B": (
        "Instrumental, 46 seconds, around 140 BPM with a half-time feel, dark cinematic electronic. "
        "Opens hollow and institutional: a single sustained piano chord in a marble hall with long "
        "reverb and a slow ticking clock, sparse and heavy. Then the machine arrives: arpeggiated analog "
        "synths, data blips, a sidechained pad, a deep 808 sub, momentum building. Then many small "
        "plucked bell voices in polyrhythm that converge and resolve into one sustained note, followed "
        "by a riser and a steady mechanical pulse. Then ONE massive brass braam with a sub boom and a "
        "stamp, after which the harmony lifts from minor to major and rings out, decaying to silence. "
        "Clear changes of texture every few seconds, nothing loops unchanged. Cinematic, clean, "
        "mastered, no vocals."
    ),
}


def api(path: str, token: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        "https://api.replicate.com/v1" + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST" if body is not None else "GET",
    )
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 7:
                raise
            wait = 20 * (attempt + 1)
            print(f"  429 from Replicate, waiting {wait}s", flush=True)
            time.sleep(wait)


def main() -> None:
    token = os.environ.get("REPLICATE_API_TOKEN")
    if not token:
        sys.exit("REPLICATE_API_TOKEN is not set")
    film = sys.argv[1].upper()
    takes = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    RAW.mkdir(parents=True, exist_ok=True)
    existing = len(list(RAW.glob(f"{film}-*.wav")))
    log = RAW / f"{film}-predictions.jsonl"
    for i in range(existing + 1, existing + takes + 1):
        body = {
            "input": {
                "prompt": PROMPTS[film],
                "music_length_ms": LENGTH_MS,
                "force_instrumental": True,
                "output_format": "wav_cd_quality",
            }
        }
        p = api(f"/models/{MODEL}/predictions", token, body)
        pid = p["id"]
        print(f"{film}-{i}: prediction {pid} {p['status']}", flush=True)
        while p["status"] not in ("succeeded", "failed", "canceled"):
            time.sleep(4)
            p = api(f"/predictions/{pid}", token)
        if p["status"] != "succeeded":
            print(f"  FAILED: {p.get('error')}")
            continue
        url = p["output"] if isinstance(p["output"], str) else p["output"][0]
        out = RAW / f"{film}-{i}.wav"
        with urllib.request.urlopen(url, timeout=300) as r:
            out.write_bytes(r.read())
        with log.open("a") as f:
            f.write(json.dumps({"take": out.name, "id": pid, "metrics": p.get("metrics"), "created_at": p.get("created_at"), "version": p.get("version"), "input": body["input"]}) + "\n")
        print(f"  wrote {out.name} ({out.stat().st_size} bytes), predict time {p.get('metrics', {}).get('predict_time')}")


if __name__ == "__main__":
    main()
