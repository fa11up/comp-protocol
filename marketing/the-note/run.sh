#!/usr/bin/env bash
# usage: run.sh page.html outdir   -- renders the page in headless Chrome and decodes every "name<TAB>base64" line of #out to outdir/name.png
set -e
here="$(cd "$(dirname "$0")" && pwd)"
page="$1"; out="$2"; mkdir -p "$out"
google-chrome --headless=new --no-sandbox --disable-gpu --allow-file-access-from-files --virtual-time-budget=120000 \
  --dump-dom "file://$here/$page" > "$out/.dom.html" 2>/dev/null
python3 - "$out" <<'PY'
import sys,re,base64,html
out=sys.argv[1]
d=open(out+"/.dom.html").read()
m=re.search(r'<pre id="out">(.*?)</pre>',d,re.S)
for line in html.unescape(m.group(1)).split("\n"):
    if "\t" in line:
        n,b=line.split("\t"); open(f"{out}/{n}.png","wb").write(base64.b64decode(b)); print("wrote",n)
PY
rm -f "$out/.dom.html"
