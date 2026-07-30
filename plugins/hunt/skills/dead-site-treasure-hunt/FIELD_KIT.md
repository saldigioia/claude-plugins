# Field Kit — copy-paste commands

Set once:
```bash
D=example.com        # the dead domain
IP=203.0.113.10      # origin IP (from dig, once known)
H=www.example.com    # the host whose cert/vhost you're hitting
```

---

## §Recon

**DNS triage — every name can point somewhere different:**
```bash
for h in "" www. cpanel. webmail. webdisk. ftp. mail. api. cdn. assets. img. images. \
         media. static. m. mobile. blog. shop. store. v2. v3. old. staging. dev. beta.; do
  printf "%-28s %s\n" "$h$D" "$(dig +short ${h}$D A ${h}$D CNAME | tr '\n' ' ')"
done
```

**Front door — GET (not just HEAD; parked apexes 405 on HEAD):**
```bash
curl -sSIL "https://$D/" | grep -iE 'HTTP/|location|server|x-powered'   # redirect target? server?
curl -sSL  "https://$D/" | head -c 600                                   # SPA? parked lander?
```

**Cert transparency — owner's full host family:**
```bash
curl -s "https://crt.sh/?q=$D&output=json"      | python3 -c 'import sys,json;print("\n".join(sorted({n for r in json.load(sys.stdin) for n in r["name_value"].split(chr(10))})))'
curl -s "https://crt.sh/?q=%25.$D&output=json"  | python3 -c 'import sys,json;print("\n".join(sorted({n for r in json.load(sys.stdin) for n in r["name_value"].split(chr(10))})))' 2>/dev/null
```

**Reverse-IP (shared vs dedicated):**
```bash
curl -s "https://api.hackertarget.com/reverseiplookup/?q=$IP" | head -40
```

**Wayback CDX census — complete, all subdomains/mimetypes:**
```bash
curl -s "http://web.archive.org/cdx/search/cdx?url=$D&matchType=domain&output=text\
&fl=original,timestamp,mimetype,statuscode&collapse=urlkey" > cdx.txt
wc -l cdx.txt
# subdomains ever seen:
sed -E 's#^https?://([^/:]+).*#\1#' cdx.txt | sort -u
# top-level dirs:
sed -E 's#^https?://[^/]+/##; s#/.*##; s#\?.*##' cdx.txt | grep -vE '^$|\.' | sort | uniq -c | sort -rn
# every archived image URL:
grep -iE '\.(jpg|jpeg|png|tif|tiff|gif|webp)( |$)' cdx.txt
```

**Reach a host DNS has moved away from (SNI-pin to the old origin):**
```bash
curl -sS --resolve "$H:443:$IP" "https://$H/path"   # cert must match $H; use www if apex cert is absent
```

---

## §Liveness — the four-way read

```bash
probe(){ curl -sS -m15 -o /dev/null -w "%{http_code} %{size_download}b %{content_type} | $1\n" "https://$H$1"; }
# 200 open-index/file · 403 EXISTS-hidden (attack sub-paths) · 404 gone · 301 redirected-away
for p in / /old/ /images/ /photos/ /gallery/ /portfolio/ /wp-content/ /src/ /admin/ /backup/; do probe "$p"; done
```

**SPA catch-all fake-200 test — verify a "find" is real content:**
```bash
probe "/some/real/looking/path/"                 # 200?
probe "/zzz_garbage_$(echo $RANDOM).tif"          # if THIS is also 200 same-size -> catch-all, not content
```

---

## §Autoindex — parse an open Apache directory listing

```python
# find masters by the Size column without downloading anything
import re, urllib.request
def index(url):
    t=urllib.request.urlopen(url,timeout=30).read().decode('latin1')
    ROW=re.compile(r'<a href="([^"?][^"]*)">[^<]*</a>\s*</td><td[^>]*>([^<]*)</td><td[^>]*>\s*([0-9.]+[KMG]?|-)\s*</td>',re.I)
    m={'K':1024,'M':1024**2,'G':1024**3}
    def b(s):
        s=s.strip(); u=s[-1:]
        return int(float(s[:-1])*m[u]) if u in m else (int(float(s)) if s not in('-','') else -1)
    return [(h, b(sz), sz.strip()) for h,mod,sz in ROW.findall(t)]  # (name, bytes, human)
# recurse dirs (names ending '/'); sort files by bytes desc -> master candidates
```

Bash quick-look of the biggest files in a listing:
```bash
curl -s "https://$H/dir/" | grep -oiE '<a href="[^"?][^"]*">|[0-9.]+[KMG]</td>' | paste - - | sort -t'>' -k2 -rh | head
```

---

## §Extract — mirror + backfill

**Polite wget mirror of an open index (kills Apache sort-link dupes):**
```bash
wget --mirror --no-parent --no-host-directories --page-requisites \
     --reject-regex '(\?C=|\?N=|\?M=|\?S=|\?D=|\?O=)' \
     --wait=0.25 --random-wait --tries=3 --timeout=40 \
     -e robots=off -U "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1" \
     "https://$H/dir/"
```

**Backfill: diff the authoritative index against disk, curl the gaps** (crawlers miss index-only files):
```python
import os, subprocess, urllib.parse
# inventory = [url paths from the open-index walk]; ROOT = local mirror root
for urlpath in inventory:
    local=os.path.join(ROOT, urllib.parse.unquote(urlpath.lstrip('/')))
    if os.path.exists(local) and os.path.getsize(local)>0: continue
    os.makedirs(os.path.dirname(local),exist_ok=True)
    seg='/'.join(urllib.parse.quote(urllib.parse.unquote(s)) for s in urlpath.lstrip('/').split('/'))
    subprocess.run(["curl","-sS","-m60","--retry","2","-o",local, f"https://{H}/{seg}"])
```

---

## §Verify — dimensions without the download

```bash
curl -sS -r 0-400000 "$URL" -o head.bin && file head.bin   # WxH + camera for TIFF/JPEG headers
```
```python
# TIFF IFD width/height from the first bytes
import struct; d=open('head.bin','rb').read(); bo='<' if d[:2]==b'II' else '>'
off=struct.unpack(bo+'I',d[4:8])[0]; n=struct.unpack(bo+'H',d[off:off+2])[0]
t={struct.unpack(bo+'H',d[off+2+i*12:off+4+i*12])[0]: struct.unpack(bo+'I',d[off+10+i*12:off+14+i*12])[0] for i in range(n)}
print(t.get(256),'x',t.get(257))          # 256=ImageWidth 257=ImageLength; 271/272=Make/Model
```
```bash
exiftool -S -ImageSize -Model -LensModel -DateTimeOriginal -SerialNumber "$file"   # if installed
```

---

## §Branch C — Wayback raw recovery

```bash
# original bytes (id_), NOT the rewritten viewer page:
curl -sS "https://web.archive.org/web/<timestamp>id_/http://$D/path/file.jpg" -o file.jpg
# authoritative "never archived" check before declaring a dead end:
curl -s "https://archive.org/wayback/available?url=$D/path/file.jpg"   # {"archived_snapshots":{}} = truly gone
# bulk: every 200 image capture, into a mirror preserving path structure
grep -iE ' 200 .*\.(jpg|jpeg|png|tif|gif)$' cdx.txt | awk '{print $2, $1}' | while read ts url; do
  out="_wayback_recovered/$(echo "$url" | sed -E 's#^https?://[^/]+/##')"; mkdir -p "$(dirname "$out")"
  curl -sS "https://web.archive.org/web/${ts}id_/$url" -o "$out"
done
```

---

## §Branch D — cloud bucket listing

```bash
curl -s "https://BUCKET.s3.amazonaws.com/?list-type=2&max-keys=1000"        # public S3 list
curl -s "https://BUCKET.s3.amazonaws.com/?list-type=2&prefix=images/"        # scoped
curl -s "https://storage.googleapis.com/BUCKET/?prefix=&max-keys=1000"       # GCS XML list
# bucket name usually leaks in the SPA JS: grep app.*.js for amazonaws|storage.googleapis|r2.dev|blob.core
```

---

## §Deliverables template

- `CITATIONS.md` — provenance (host/IP, access method, retrieval date), per-folder source URLs, master table.
- `manifest.csv` — `local,url,bytes,mtime,sha256,ext` (one row/file). Build by walking the mirror + `hashlib.sha256`.
- `FILE_TREE.txt` — indented tree with per-folder image/byte counts; inline-flag `★MASTER` files ≥1 MB / TIFF.
- Dead-ends section — what was tried + the disproving evidence.
