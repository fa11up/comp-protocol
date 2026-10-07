#!/usr/bin/env python3
"""Regenerate film B's dissolve keyframe (K3) with image-editing models on Replicate.

User's direction (2026-10-07): after the wipe, BOTH sides of the room are clocks and computers, and the
standing figure is a robot raising the coin. The edit starts from the accepted K3 so perspective, style and
the coin's place hold; candidates go to edit-k3/<model>-<n>.png for picking by eye.

    REPLICATE_API_TOKEN=... python3 marketing/explainer/film-b/edit_k3.py [takes per model]
"""
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
SRC = HERE / "keyframes" / "k3-dissolve.png"
OUT = HERE / "edit-k3"
PROMPT = (
    "Edit this steel-engraved banknote-style illustration. Keep exactly the same engraving style, fine intaglio "
    "hatching, palette (ivory paper, dark navy ink, engraved green), camera angle, perspective and composition, "
    "and keep the long table running down the middle toward the arched window. Change only two things. "
    "(1) Replace everything on the LEFT side of the room (the seated people, the left wall, the hanging banner, "
    "the window and the potted trees) with the same wall of engraved instrument panels that fills the right side: "
    "round dials with needles, meters, knobs and small screens with green traces, so both sides of the room are "
    "machines, roughly mirrored around the centre. No people sit at the table. "
    "(2) Turn the standing central figure into a humanoid robot drawn in the same engraved hatching, same pose and "
    "place, still raising the round coin high in its right hand. Keep the coin plain and blank in the same place. "
    "No text, letters, numbers or logos anywhere. 16:9."
)
MODELS = {
    "nano-banana": ("google/nano-banana", lambda url: {"prompt": PROMPT, "image_input": [url], "aspect_ratio": "16:9", "output_format": "png"}),
    "kontext": ("black-forest-labs/flux-kontext-pro", lambda url: {"prompt": PROMPT, "input_image": url, "aspect_ratio": "16:9", "output_format": "png", "safety_tolerance": 2}),
    "seedream": ("bytedance/seedream-4", lambda url: {"prompt": PROMPT, "image_input": [url], "size": "2K", "aspect_ratio": "16:9"}),
}


def call(method, path, token, body=None, raw=None, ctype="application/json"):
    req = urllib.request.Request("https://api.replicate.com/v1" + path, method=method,
                                 data=raw if raw is not None else (json.dumps(body).encode() if body else None),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": ctype})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 7:
                raise RuntimeError(f"{e.code} {e.read()[:300]}")
            time.sleep(15 * (attempt + 1))


def upload(path, token):
    boundary = "----k3edit"
    data = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"content\"; filename=\"{path.name}\"\r\n"
            f"Content-Type: image/png\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    f = call("POST", "/files", token, raw=data, ctype=f"multipart/form-data; boundary={boundary}")
    return f["urls"]["get"]


ROBOT = (
    "Edit this steel-engraved illustration. Keep everything exactly as it is: the engraving style, hatching, palette, "
    "both walls of instrument panels, the table, the arched window and landscape, the composition, and the raised "
    "round coin, plain and blank, in exactly the same place and size. Change ONLY the standing figure in the middle: "
    "make it a humanoid robot (metal head, jointed arms, armoured torso) drawn in the same fine engraved hatching and "
    "dark navy ink, seen from behind in exactly the same pose, raising the coin with its right hand. "
    "No text, letters, numbers or logos anywhere. 16:9."
)


def main():
    token = os.environ["REPLICATE_API_TOKEN"]
    if len(sys.argv) > 2 and sys.argv[1] == "robot":
        # second pass: robot only, starting from a chosen first-pass frame
        src = OUT / sys.argv[2]; takes = int(sys.argv[3]) if len(sys.argv) > 3 else 2
        url = upload(src, token)
        for n in range(1, takes + 1):
            p = call("POST", "/models/google/nano-banana/predictions", token,
                     {"input": {"prompt": ROBOT, "image_input": [url], "aspect_ratio": "16:9", "output_format": "png"}})
            while p["status"] not in ("succeeded", "failed", "canceled"):
                time.sleep(3); p = call("GET", f"/predictions/{p['id']}", token)
            if p["status"] != "succeeded":
                print("robot", n, "FAILED", p.get("error")); continue
            o = p["output"]; o = o[0] if isinstance(o, list) else o
            dst = OUT / f"robot-{src.stem}-{n}.png"
            with urllib.request.urlopen(o, timeout=300) as r:
                dst.write_bytes(r.read())
            print("robot", n, "->", dst.name)
        return
    takes = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    OUT.mkdir(exist_ok=True)
    url = upload(SRC, token)
    for key, (model, inp) in MODELS.items():
        for n in range(1, takes + 1):
            try:
                p = call("POST", f"/models/{model}/predictions", token, {"input": inp(url)})
                while p["status"] not in ("succeeded", "failed", "canceled"):
                    time.sleep(3); p = call("GET", f"/predictions/{p['id']}", token)
                if p["status"] != "succeeded":
                    print(key, n, "FAILED", p.get("error")); continue
                o = p["output"]; o = o[0] if isinstance(o, list) else o
                dst = OUT / f"{key}-{n}.png"
                with urllib.request.urlopen(o, timeout=300) as r:
                    dst.write_bytes(r.read())
                print(key, n, "->", dst.name, p.get("metrics", {}).get("predict_time"))
            except Exception as e:
                print(key, n, "ERROR", e)


if __name__ == "__main__":
    main()
