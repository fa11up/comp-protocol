#!/usr/bin/env python3
"""Fetch 1-minute OHLCV (price in ETH per IMD, currency=token) for the IMD/ETH v4 pool
from GeckoTerminal's public API, paginating backwards to pool creation. No API key.
Output: gt_minute.json  [[ts, o, h, l, c, vol_eth], ...] ascending, deduped."""
import json, time, urllib.request, sys
POOL = "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3"
URL = "https://api.geckoterminal.com/api/v2/networks/eth/pools/%s/ohlcv/minute?aggregate=1&limit=1000&currency=token&before_timestamp=%d"
CREATED = 1785353567  # 2026-07-29T19:32:47Z
rows = {}
before = int(time.time()) + 60
while True:
    for attempt in range(6):
        try:
            req = urllib.request.Request(URL % (POOL, before), headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"})
            d = json.load(urllib.request.urlopen(req, timeout=30))
            break
        except Exception as e:
            print("retry", e, file=sys.stderr); time.sleep(10 * (attempt + 1))
    else:
        sys.exit("gave up")
    lst = d["data"]["attributes"]["ohlcv_list"]
    if not lst: break
    for r in lst: rows[r[0]] = r
    oldest = min(r[0] for r in lst)
    print(len(rows), time.strftime("%Y-%m-%d %H:%M", time.gmtime(oldest)), file=sys.stderr)
    if oldest >= before or oldest <= CREATED: break
    before = oldest
    time.sleep(2.2)
out = sorted(rows.values())
json.dump(out, open("gt_minute.json", "w"))
print("rows", len(out), out[0][0], out[-1][0])
