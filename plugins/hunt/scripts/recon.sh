#!/usr/bin/env bash
#
# recon.sh — Phase 1 RECON for a dead / defunct / parked / redirected site.
#
# Answers the one question that dictates every later move: WHAT IS STILL ALIVE,
# AND WHERE? Runs the six probes from the `dead-site-treasure-hunt` skill, then
# classifies the front door and names the branch(es) to run in Phase 2.
#
# The probes hit different hosts, so the third-party lookups (crt.sh, Wayback,
# CommonCrawl, reverse-IP) run concurrently. Liveness probes against the origin
# are deliberately SERIALIZED — a fragile legacy box rate-limits by IP and
# answers EMPTY rather than 429, which silently corrupts enumeration.
#
# Usage:
#   recon.sh [options] <domain>
#
#   -o DIR        output directory (default: ./recon-<domain>)
#   -H HOST       host to run liveness probes against (default: auto-detect)
#   -p FILE       newline-separated extra paths to probe (merged with defaults)
#   -d SECONDS    delay between liveness probes (default: 0.3)
#      --no-archive     skip the Wayback CDX census and CommonCrawl
#      --no-liveness    skip the four-way liveness read
#      --no-third-party skip crt.sh and reverse-IP
#   -h, --help    this text
#
# Writes into the output directory:
#   RECON.md            the dossier — classification, live hosts, branch routing
#   dns.txt             per-subdomain A/CNAME
#   frontdoor.txt       apex + www headers and body head
#   crtsh.txt           certificate-transparency host family
#   reverseip.txt       neighbours on the origin IP
#   cdx.txt             full Wayback census (all subdomains, all depths)
#   cdx-subdomains.txt  every subdomain ever archived
#   cdx-dirs.txt        top-level + deep dirs, by capture count
#   cdx-images.txt      every archived image URL
#   commoncrawl.txt     CommonCrawl index hits (when Wayback is thin)
#   liveness.txt        four-way read: 200 / 403 / 404 / 301 per path
#   registry-stub.md    pre-filled lore entry to move into the plugin registry
#
# Nothing here downloads assets. This phase only builds the map.
# Requirements: curl, dig. Optional: python3 (crt.sh + CommonCrawl parsing).

set -uo pipefail   # NOT -e: probe failures are data, not errors.

# ── defaults ─────────────────────────────────────────────────────────────────

OUTDIR=""
PROBE_HOST=""
EXTRA_PATHS=""
DELAY="0.3"
DO_ARCHIVE=true
DO_LIVENESS=true
DO_THIRD_PARTY=true

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

# Subdomains worth trying on a dead site. cpanel/webmail/webdisk/ftp are the
# high-value tells: a live control-panel host means the ORIGIN account is still
# up even when the apex is parked.
SUBDOMAINS=(
  "" www. cpanel. webmail. webdisk. ftp. mail. autodiscover. api. cdn. assets.
  img. images. media. static. files. downloads. m. mobile. blog. shop. store.
  news. photos. gallery. portfolio. archive. v2. v3. old. legacy. staging.
  dev. beta. test. app. admin. secure. support.
)

# Paths for the four-way liveness read. Bias toward asset trees and the
# generator layouts old photo/portfolio sites shipped.
DEFAULT_PATHS=(
  / /old/ /new/ /archive/ /archives/
  /images/ /image/ /img/ /photos/ /photo/ /pics/ /pictures/ /media/ /assets/
  /gallery/ /galleries/ /portfolio/ /work/ /projects/ /albums/
  /files/ /downloads/ /uploads/ /content/ /data/ /src/ /static/
  /wp-content/ /wp-content/uploads/ /wp-admin/ /wp-json/wp/v2/media
  /content/bin/ /content/bin/images/ /content/bin/images/large/
  /thumbnails/ /pages/ /slides/ /originals/ /original/ /hires/ /highres/
  /admin/ /backup/ /backups/ /bak/ /tmp/ /test/ /private/ /_vti_cnf/
  /sitemap.xml /robots.txt /.well-known/ /crossdomain.xml
)

# ── plumbing ─────────────────────────────────────────────────────────────────

die() { printf 'recon: %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="${2:?-o needs a directory}"; shift 2 ;;
    -H) PROBE_HOST="${2:?-H needs a host}"; shift 2 ;;
    -p) EXTRA_PATHS="${2:?-p needs a file}"; shift 2 ;;
    -d) DELAY="${2:?-d needs seconds}"; shift 2 ;;
    --no-archive) DO_ARCHIVE=false; shift ;;
    --no-liveness) DO_LIVENESS=false; shift ;;
    --no-third-party) DO_THIRD_PARTY=false; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [[ -n "${DOMAIN:-}" ]] && die "one domain at a time"; DOMAIN="$1"; shift ;;
  esac
done

[[ -n "${DOMAIN:-}" ]] || usage 1
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v dig  >/dev/null 2>&1 || note "warning: dig not found — DNS triage will be skipped"

# Accept a full URL, a bare host, or something with a trailing dot/slash.
D="$DOMAIN"
D="${D#*://}"      # strip scheme
D="${D%%/*}"       # strip path
D="${D%%:*}"       # strip port
D="${D%.}"         # strip trailing dot
D="${D#www.}"      # normalize to the apex; www is probed explicitly
[[ "$D" == *.* ]] || die "'$DOMAIN' does not look like a domain"

OUTDIR="${OUTDIR:-./recon-$D}"
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

say "RECON $D"
note "output: $OUTDIR"
note "started: $STAMP"
echo

# curl with sane bounds. Never let one hung host stall the run.
c() { curl -sS -A "$UA" --connect-timeout 10 --max-time 45 "$@"; }

# ── probe 1: DNS triage ──────────────────────────────────────────────────────
# Every name can point somewhere different. The apex being parked says nothing
# about whether the original box still answers on www/cpanel.

# WILDCARD_IPS is set by dns_triage: non-empty means the zone answers for ANY
# name, so a resolving subdomain proves nothing. This is the DNS-layer twin of
# the SPA catch-all fake-200, and it will fabricate a whole host family if you
# don't test for it.
WILDCARD_IPS=""

dns_triage() {
  command -v dig >/dev/null 2>&1 || { echo "dig unavailable — skipped" > "$OUTDIR/dns.txt"; return; }

  WILDCARD_IPS="$(dig +short +time=3 +tries=1 "zzz-recon-guard-84713.$D" A 2>/dev/null \
                  | grep -E '^[0-9.]+$' | sort | tr '\n' ' ' | sed 's/ *$//')"

  : > "$OUTDIR/dns.txt"
  if [[ -n "$WILDCARD_IPS" ]]; then
    {
      echo "# !! WILDCARD DNS: a bogus name resolves to: $WILDCARD_IPS"
      echo "# Names marked [wildcard] below are NOT evidence that anything exists there."
      echo "# Only names resolving ELSEWHERE (unmarked) are real, and only HTTP can confirm any of them."
      echo
    } >> "$OUTDIR/dns.txt"
  fi

  for h in "${SUBDOMAINS[@]}"; do
    local name="${h}${D}" a cn tag=""
    a="$(dig +short +time=3 +tries=1 "$name" A 2>/dev/null | grep -E '^[0-9.]+$' | sort | tr '\n' ' ' | sed 's/ *$//')"
    cn="$(dig +short +time=3 +tries=1 "$name" CNAME 2>/dev/null | tr '\n' ' ')"
    [[ -z "$a$cn" ]] && continue
    [[ -n "$WILDCARD_IPS" && "$a" == "$WILDCARD_IPS" ]] && tag=" [wildcard]"
    printf '%-34s A=%-46s CNAME=%s%s\n' "$name" "${a:--}" "${cn:--}" "$tag" >> "$OUTDIR/dns.txt"
  done
  grep -q '^[a-z0-9]' "$OUTDIR/dns.txt" 2>/dev/null || echo "(no names resolved)" >> "$OUTDIR/dns.txt"
}

# The IP worth reversing is the ORIGIN candidate, not the apex. A parked apex
# points at a registrar/AWS lander whose neighbours are unrelated spam tenants;
# the legacy box behind www/cpanel is the real footprint. Echoes "label ip" rows.
origin_ip_candidates() {
  local seen="" h ip label
  for h in "cpanel.$D" "www.$D" "$D"; do
    ip="$(dig +short +time=3 +tries=1 "$h" A 2>/dev/null | grep -m1 -E '^[0-9.]+$')"
    [[ -z "$ip" ]] && continue
    [[ -n "$WILDCARD_IPS" && "$h" == "cpanel.$D" && " $WILDCARD_IPS" == *" $ip "* ]] && label="cpanel(wildcard)" || label="$h"
    case " $seen " in *" $ip "*) continue ;; esac
    seen="$seen $ip"
    printf '%s %s\n' "$label" "$ip"
  done
}

# ── probe 2: the current front door ──────────────────────────────────────────
# GET, never HEAD alone: parked apexes routinely 405 on HEAD and serve on GET.

front_door() {
  : > "$OUTDIR/frontdoor.txt"
  local host
  for host in "$D" "www.$D"; do
    {
      echo "=== https://$host/ ==="
      echo "--- headers (-sSIL) ---"
      c -IL "https://$host/" 2>&1 | grep -iE '^(HTTP/|location:|server:|x-powered-by:|x-vercel|x-nf-|cf-|content-type:|content-length:)' || echo "(no response)"
      echo "--- body head (GET, first 900 bytes) ---"
      c -L "https://$host/" 2>&1 | head -c 900
      echo
      echo
    } >> "$OUTDIR/frontdoor.txt" 2>&1
  done
}

# Classify the front door from what front_door() captured.
# Echoes: "<CLASS>|<detail>" — PARKED, REDIRECTED, SPA, LIVE, DEAD, UNKNOWN.
classify_front_door() {
  local f="$OUTDIR/frontdoor.txt" body loc code
  [[ -s "$f" ]] || { echo "UNKNOWN|no front-door capture"; return; }
  body="$(tr -d '\0' < "$f")"
  loc="$(grep -im1 '^location:' "$f" | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
  code="$(grep -om1 'HTTP/[0-9.]* [0-9]\{3\}' "$f" | grep -o '[0-9]\{3\}$')"

  if grep -qiE 'godaddy|sedoparking|afternic|hugedomains|dan\.com|parkingcrew|bodis|domain (is )?for sale|buy this domain|this domain (may be|is) for sale' <<<"$body"; then
    echo "PARKED|registrar/parking lander — dead front; go to origin (Branch A) or archive (Branch C)"; return
  fi
  if [[ -n "$loc" ]]; then
    local target="${loc#*://}"; target="${target%%/*}"; target="${target#www.}"
    if [[ -n "$target" && "$target" != "$D" ]]; then
      echo "REDIRECTED|301/302 → $target — the owner moved; that target has its own live backend (Branch B). NOTE: a root redirect is usually a root-only .htaccess rule — sub-directories often bypass it (Branch A)"; return
    fi
  fi
  if grep -qiE 'id="(app|root|__next|__nuxt)"|__NEXT_DATA__|/_next/|/page-data/|prerender\.io|netlify|vercel|cloudflare-pages|window\.__NUXT__' <<<"$body"; then
    echo "SPA|modern SPA — the treasure surface is its backend/CMS API (Branch B). Watch for the catch-all fake-200"; return
  fi
  case "$code" in
    2*) echo "LIVE|server answers with real content — probe the docroot (Branch A)" ;;
    3*) echo "REDIRECTED|redirect without a resolvable target — inspect frontdoor.txt" ;;
    4*|5*) echo "DEAD|front door $code — check origin subdomains, then the archive (Branch C)" ;;
    *) echo "UNKNOWN|no HTTP status captured — host may not answer at all (Branch C/D)" ;;
  esac
}

# ── probe 3: certificate transparency ────────────────────────────────────────
# The owner's whole host family, including addon domains and api./v3. hosts the
# frontend never links.

# crt.sh is slow (5-30s) and rate-limits/502s under concurrent load, so it gets
# its own generous timeout and one retry. The raw body is kept so an empty result
# can be told apart from a genuine no-records answer.
crt_sh() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable — skipped" > "$OUTDIR/crtsh.txt"; return; }
  local parse
  parse='import sys,json
try: rows=json.load(sys.stdin)
except Exception: sys.exit(0)
names=set()
for r in rows:
    for n in (r.get("name_value") or "").split("\n"):
        n=n.strip().lstrip("*.").lower()
        if n: names.add(n)
print("\n".join(sorted(names)))'

  local q raw code attempt
  : > "$OUTDIR/crtsh.txt"
  for q in "$D" "%25.$D"; do
    raw="$OUTDIR/.crtsh-raw-$(printf '%s' "$q" | tr -c 'a-zA-Z0-9.' '_')"
    for attempt in 1 2; do
      code="$(curl -sS -A "$UA" --connect-timeout 15 --max-time 90 \
              -o "$raw" -w '%{http_code}' "https://crt.sh/?q=$q&output=json" 2>/dev/null)"
      [[ "$code" == "200" && -s "$raw" ]] && break
      [[ $attempt == 1 ]] && sleep 4
    done
    if [[ "$code" == "200" && -s "$raw" ]]; then
      python3 -c "$parse" < "$raw" >> "$OUTDIR/crtsh.txt" 2>/dev/null
    else
      printf '# query %s failed (HTTP %s) — crt.sh rate-limits under load; re-run later\n' \
        "$q" "${code:-none}" >> "$OUTDIR/crtsh.txt"
    fi
    rm -f "$raw"
  done
  sort -u -o "$OUTDIR/crtsh.txt" "$OUTDIR/crtsh.txt"
  grep -q '^[a-z0-9]' "$OUTDIR/crtsh.txt" 2>/dev/null || \
    echo "(no CT hostnames recovered — see the failure lines above)" >> "$OUTDIR/crtsh.txt"
}

# ── probe 4: reverse IP ──────────────────────────────────────────────────────
# Shared registrar IP = unrelated tenants, don't chase. Dedicated = real footprint.

reverse_ip() {
  local rows
  rows="$(origin_ip_candidates)"
  if [[ -z "$rows" ]]; then echo "(no A record to reverse)" > "$OUTDIR/reverseip.txt"; return; fi
  : > "$OUTDIR/reverseip.txt"
  local label ip n
  while read -r label ip; do
    [[ -z "$ip" ]] && continue
    {
      printf '=== %s -> %s ===\n' "$label" "$ip"
      c "https://api.hackertarget.com/reverseiplookup/?q=$ip" 2>&1 | head -120
      echo
    } >> "$OUTDIR/reverseip.txt"
    sleep 1
  done <<< "$rows"
  # A big neighbour count means a shared registrar/CDN IP — unrelated tenants,
  # don't chase them. A small count means a dedicated box: the real footprint.
  n="$(grep -cE '^[a-z0-9.-]+\.[a-z]{2,}$' "$OUTDIR/reverseip.txt" 2>/dev/null || echo 0)"
  printf '\n# %s neighbour names total — many = shared/parking IP (ignore); few = dedicated origin (chase)\n' \
    "$n" >> "$OUTDIR/reverseip.txt"
}

# ── probe 5: Wayback CDX census ──────────────────────────────────────────────
# matchType=domain is authoritative: every subdomain, every depth, untruncated.
# (A trailing-* with matchType=prefix sometimes returns 0 rows — syntax quirk.)

cdx_census() {
  local base="http://web.archive.org/cdx/search/cdx?url=$D&matchType=domain&output=text&fl=original,timestamp,mimetype,statuscode&collapse=urlkey"
  curl -sS -A "$UA" --connect-timeout 15 --max-time 300 "$base" > "$OUTDIR/cdx.txt" 2>/dev/null

  # Completeness check — 1 page means we have the whole census in one request.
  local pages
  pages="$(c "http://web.archive.org/cdx/search/cdx?url=$D&matchType=domain&showNumPages=true" 2>/dev/null | tr -d '[:space:]')"
  printf '# pages reported by CDX: %s (1 = this census is complete)\n' "${pages:-unknown}" > "$OUTDIR/cdx-pages.txt"

  if [[ ! -s "$OUTDIR/cdx.txt" ]]; then
    echo "(no Wayback captures for $D — check archive.org/wayback/available before dead-ending)" > "$OUTDIR/cdx.txt"
    return
  fi

  # every subdomain ever archived
  sed -E 's#^https?://([^/:]+).*#\1#' "$OUTDIR/cdx.txt" | sort | uniq -c | sort -rn > "$OUTDIR/cdx-subdomains.txt"
  # dir inventory: top-level and second-level, by capture count
  awk '{print $1}' "$OUTDIR/cdx.txt" \
    | sed -E 's#^https?://[^/]+##; s#\?.*##' \
    | grep -E '^/' \
    | awk -F/ 'NF>2 {print "/"$2"/"} NF>3 {print "/"$2"/"$3"/"}' \
    | grep -vE '\.[a-zA-Z0-9]{2,5}/$' \
    | sort | uniq -c | sort -rn > "$OUTDIR/cdx-dirs.txt"
  # every archived image URL
  grep -iE '\.(jpg|jpeg|png|tif|tiff|gif|webp|bmp|psd|heic)([[:space:]]|$)' "$OUTDIR/cdx.txt" \
    > "$OUTDIR/cdx-images.txt"
}

# ── probe 6: CommonCrawl index ───────────────────────────────────────────────
# Worth it when Wayback is thin; WARC offsets give raw bytes Wayback may lack.

common_crawl() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable — skipped" > "$OUTDIR/commoncrawl.txt"; return; }
  local idx
  idx="$(c "https://index.commoncrawl.org/collinfo.json" 2>/dev/null \
        | python3 -c 'import sys,json
try: print(json.load(sys.stdin)[0]["id"])
except Exception: pass' 2>/dev/null)"
  if [[ -z "$idx" ]]; then echo "(collinfo.json unreachable — skipped)" > "$OUTDIR/commoncrawl.txt"; return; fi
  { printf '# index: %s\n' "$idx"
    curl -sS -A "$UA" --connect-timeout 15 --max-time 120 \
      "https://index.commoncrawl.org/$idx-index?url=*.$D&output=json&limit=500" 2>&1 | head -500
  } > "$OUTDIR/commoncrawl.txt"
}

# ── the four-way liveness read ───────────────────────────────────────────────
#   200 = live file OR open directory index  → crawl it
#   403 = EXISTS but forbidden/no-index      → attack sub-paths (it's on disk)
#   404 = gone                               → skip
#   301 = redirected away                    → note the target (Branch B)
# Serialized on purpose: one host, one queue.

liveness() {
  local host="$1"
  local -a paths=() candidates=("${DEFAULT_PATHS[@]}")
  if [[ -n "$EXTRA_PATHS" && -f "$EXTRA_PATHS" ]]; then
    while IFS= read -r line; do
      line="${line%$'\r'}"
      [[ -n "${line// /}" && "$line" != \#* ]] && candidates+=("$line")
    done < "$EXTRA_PATHS"
  fi
  # Dedupe: -p paths routinely overlap the defaults, and probing a fragile origin
  # twice for the same path is exactly the concurrency it answers empty to.
  local nl p
  nl=$'\n'
  local seen="$nl"
  for p in "${candidates[@]}"; do
    [[ "$seen" == *"$nl$p$nl"* ]] && continue
    seen="$seen$p$nl"
    paths+=("$p")
  done

  {
    echo "# four-way liveness read against https://$host"
    echo "# 200 live/open-index · 403 EXISTS-hidden (attack sub-paths) · 404 gone · 30x redirected-away"
    echo

    # Catch-all guard FIRST. Netlify/Vercel serve the SPA shell with HTTP 200 for
    # ANY path — a deliberately-bogus filename is the only way to tell an open
    # directory from a fake-200, and getting this wrong invents a whole treasure.
    local g1 g2
    g1="$(c -o /dev/null -w '%{http_code} %{size_download}' "https://$host/zzz_recon_guard_no_such_path_84713/" 2>/dev/null)"
    g2="$(c -o /dev/null -w '%{http_code} %{size_download}' "https://$host/zzz_recon_guard_84713.tif" 2>/dev/null)"
    echo "## catch-all guard (bogus paths — these MUST NOT be 200)"
    echo "   /zzz_recon_guard_no_such_path_84713/  -> ${g1:-no-response}"
    echo "   /zzz_recon_guard_84713.tif            -> ${g2:-no-response}"
    if [[ "${g1%% *}" == 2* || "${g2%% *}" == 2* ]]; then
      echo "   !! CATCH-ALL DETECTED: this host returns 200 for garbage paths."
      echo "      Every 200 below is suspect. Match code+size against the guard —"
      echo "      identical size means SPA shell, not content."
    else
      echo "   ok: garbage 404s, so a 200 below is meaningful."
    fi
    echo

    echo "## paths"
    local p out
    for p in "${paths[@]}"; do
      out="$(c -o /dev/null -w '%{http_code} %{size_download}b %{content_type} %{redirect_url}' "https://$host$p" 2>/dev/null)"
      printf '%-8s %s\n' "${out%% *}" "${out#* } | $p"
      sleep "$DELAY"
    done
  } > "$OUTDIR/liveness.txt" 2>&1
}

# Pick the host to probe: prefer a name that actually resolves, www before apex
# (a legacy cPanel box often keeps its cert on www while the apex has moved).
pick_probe_host() {
  [[ -n "$PROBE_HOST" ]] && { echo "$PROBE_HOST"; return; }
  if [[ -s "$OUTDIR/dns.txt" ]]; then
    local h
    for h in "www.$D" "$D"; do
      grep -q "^$h " "$OUTDIR/dns.txt" && { echo "$h"; return; }
    done
    h="$(awk '{print $1}' "$OUTDIR/dns.txt" | grep -vE '^(mail|webmail|autodiscover|ftp)\.' | head -1)"
    [[ -n "$h" ]] && { echo "$h"; return; }
  fi
  echo "$D"
}

# ── run the probes ───────────────────────────────────────────────────────────

say "probe 1/6 — DNS triage"
dns_triage
note "$(grep -c . "$OUTDIR/dns.txt" 2>/dev/null || echo 0) names resolved"

say "probe 2/6 — front door"
front_door
FD="$(classify_front_door)"
note "${FD%%|*}: ${FD#*|}"

# These hit three different third parties, so run them concurrently.
PIDS=()
if $DO_THIRD_PARTY; then
  say "probe 3/6 — certificate transparency (background)"; crt_sh & PIDS+=($!)
  say "probe 4/6 — reverse IP (background)";               reverse_ip & PIDS+=($!)
else
  note "third-party lookups skipped (--no-third-party)"
fi
if $DO_ARCHIVE; then
  say "probe 5/6 — Wayback CDX census (background)";       cdx_census & PIDS+=($!)
  say "probe 6/6 — CommonCrawl index (background)";        common_crawl & PIDS+=($!)
else
  note "archive census skipped (--no-archive)"
fi

# Liveness runs in the FOREGROUND while the above wait on remote hosts. It is the
# only sequence touching the origin, which keeps the origin at one queue.
PROBE_TARGET="$(pick_probe_host)"
if $DO_LIVENESS; then
  say "liveness — four-way read against $PROBE_TARGET (serialized)"
  liveness "$PROBE_TARGET"
  note "200: $(grep -cE '^2[0-9][0-9] ' "$OUTDIR/liveness.txt" 2>/dev/null || echo 0)  403: $(grep -cE '^40[13] ' "$OUTDIR/liveness.txt" 2>/dev/null || echo 0)  30x: $(grep -cE '^3[0-9][0-9] ' "$OUTDIR/liveness.txt" 2>/dev/null || echo 0)"
else
  note "liveness read skipped (--no-liveness)"
fi

if ((${#PIDS[@]})); then
  say "waiting on background probes"
  wait "${PIDS[@]}" 2>/dev/null
fi
echo

# ── the dossier ──────────────────────────────────────────────────────────────

cnt() { [[ -f "$1" ]] && grep -c . "$1" 2>/dev/null || echo 0; }
top() { [[ -f "$1" ]] && head -"${2:-12}" "$1" 2>/dev/null; }

CDX_ROWS="$(cnt "$OUTDIR/cdx.txt")"
CDX_IMGS="$(cnt "$OUTDIR/cdx-images.txt")"
CATCHALL="no"
grep -q 'CATCH-ALL DETECTED' "$OUTDIR/liveness.txt" 2>/dev/null && CATCHALL="YES — every 200 is suspect"
if [[ -n "$WILDCARD_IPS" ]]; then
  WILDCARD_NOTE="**YES → $WILDCARD_IPS** — a bogus name resolves, so \`[wildcard]\` rows below prove nothing. Confirm each host over HTTP before believing it exists."
else
  WILDCARD_NOTE="no — a resolving subdomain is real evidence"
fi

{
cat <<EOF
# RECON — $D

- **Run:** $STAMP
- **Front door:** **${FD%%|*}** — ${FD#*|}
- **Liveness probed against:** \`$PROBE_TARGET\`
- **SPA catch-all:** $CATCHALL
- **Wildcard DNS:** $WILDCARD_NOTE
- **Wayback rows:** $CDX_ROWS (of which $CDX_IMGS image URLs) — see \`cdx-pages.txt\` for completeness

> The archive is a map. The origin is the treasure. They are usually DISJOINT.
> Dirs Wayback saw that are now 404 were **deleted**. Dirs that are **live but
> Wayback never saw** are the survivors worth crawling — and no archive query
> will enumerate them for you.

## Live hosts (DNS)

\`\`\`
$(top "$OUTDIR/dns.txt" 40)
\`\`\`

**Tell:** a \`cpanel.\` / \`webmail.\` / \`webdisk.\` host that resolves **outside** the
wildcard means the original hosting account is still up — the origin is probably alive
even if the apex is parked. Cross-check against \`cdx-subdomains.txt\`: a control-panel
subdomain that Wayback also captured is real, wildcard or not.

Reverse-IP neighbours are in \`reverseip.txt\`, taken from the **origin-candidate** IP
(cpanel/www) rather than the apex — a parked apex reverses to unrelated tenants.

## Four-way liveness read

\`\`\`
$( [[ -f "$OUTDIR/liveness.txt" ]] && grep -E '^(2|3|40)[0-9][0-9] ' "$OUTDIR/liveness.txt" | head -40 || echo "(skipped)" )
\`\`\`

- **200** — live file or open directory index → crawl it
- **403** — exists but forbidden → attack sub-paths, the directory is on disk
- **30x** — redirected away → note the target; a root redirect rarely binds sub-dirs

## Archived path inventory (what used to exist)

Top directories by capture count:

\`\`\`
$(top "$OUTDIR/cdx-dirs.txt" 25)
\`\`\`

Subdomains ever archived:

\`\`\`
$(top "$OUTDIR/cdx-subdomains.txt" 15)
\`\`\`

## Certificate-transparency host family

\`\`\`
$(top "$OUTDIR/crtsh.txt" 25)
\`\`\`

## Next moves — Phase 2 branch routing

EOF

case "${FD%%|*}" in
  LIVE|PARKED|REDIRECTED)
    cat <<'EOF'
**Branch A — origin still answers.** The classic jackpot: content partially
deleted, docroot never de-indexed.

1. Cross `cdx-dirs.txt` against `liveness.txt`. Two lists matter: archived-but-now-404
   (deleted, go to Branch C) and **live-but-never-archived** (the survivors — crawl these).
2. Recurse every 200 that is an open index; attack sub-paths under every 403.
3. If `/` redirects away, deep paths usually still serve — the rule is root-only.
4. Fingerprint the gallery generator before crawling, then go straight to the ceiling tier:
   Photoshop Web Photo Gallery (`pages/N.htm` + `images/N.jpg`, display IS the ceiling),
   JAlbum/Lightroom (`content/bin/images/large/`), Koken, Zenphoto, Cargo, Format.
5. Mirror = crawler ∪ index backfill. `wget --mirror` misses files reachable only from
   the directory listing — enumerate the index independently, diff against disk, curl the gaps.
EOF
    ;;
esac

case "${FD%%|*}" in
  SPA|REDIRECTED)
    cat <<'EOF'

**Branch B — live headless-CMS / API backend.** The site was rebuilt; the data
sits behind a usually-public, auth-free API.

1. Fetch the SPA, pull `app.*.js`, grep for the backend: `api.`, `/lazystate`,
   `/_next/data`, `/page-data/`, `graphql`, `*.apicdn.sanity.io`, `cdn.contentful`,
   `prismic`, `amazonaws`, `cloudinary`, `imgix`.
2. Walk it for a full enumeration surface even when directory listing is 403.
3. **Trap:** the catch-all fake-200 — verify every "find" with a garbage filename
   (the guard at the top of `liveness.txt` already did this once).
EOF
    ;;
esac

case "${FD%%|*}" in
  DEAD|UNKNOWN|PARKED)
    cat <<'EOF'

**Branch C — origin dead, only the record remains.**

1. Raw bytes, not the rewritten viewer page — the `id_` suffix is mandatory:
   `https://web.archive.org/web/<ts>id_/http://<original-url>`
2. Bulk-recover from `cdx-images.txt` (every 200 image capture, path structure preserved).
3. Before declaring anything unrecoverable, get the disproving evidence:
   `curl -s "https://archive.org/wayback/available?url=<url>"` → `{"archived_snapshots":{}}`
   is the only authoritative "never archived".
4. Then CommonCrawl WARC (`commoncrawl.txt`), then `timetravel.mementoweb.org`.
5. Ceiling here is whatever the crawler happened to fetch — often only the web-display tier.
EOF
    ;;
esac

cat <<EOF

**Branch D — assets migrated to still-open cloud storage.** Grep the SPA JS and old
HTML for a bucket name (\`amazonaws\`, \`storage.googleapis\`, \`r2.dev\`, \`blob.core\`),
then list it: \`?list-type=2&prefix=\` on S3, \`?prefix=&max-keys=1000\` on GCS.

## Then

- Resolve any single recovered URL to its byte-exact master with the engine:
  \`bash tools/cdn/app.sh -o ./out '<url>'\` (48 resolvers) — or the \`/hunt:master\` command.
- Verify masters by **ranged read**, not download: \`curl -r 0-400000 "\$URL" -o head.bin && file head.bin\`.
- A camera-original filename (\`DSCF*\`, \`IMG_*\`) is **not** proof of a master; compare bytes.
- Deliver \`CITATIONS.md\` + \`manifest.csv\` (url, bytes, sha256) + \`FILE_TREE.txt\`, and
  **document dead ends with their disproving evidence** so nobody re-runs a proven-dead path.
EOF
} > "$OUTDIR/RECON.md"

# A pre-filled lore stub, so a cracked host ends up in the registry instead of
# in someone's memory.
cat > "$OUTDIR/registry-stub.md" <<EOF
# $D

- **Status:** ${FD%%|*} — ${FD#*|}
- **Recon date:** $STAMP
- **Live hosts:** $(awk '{printf "%s ", $1}' "$OUTDIR/dns.txt" 2>/dev/null | head -c 300)
- **Probe host:** $PROBE_TARGET
- **SPA catch-all:** $CATCHALL
- **Wayback:** $CDX_ROWS rows / $CDX_IMGS images

## Lever

<!-- The exact move that yields the treasure. A URL form, an API path, an open index. -->

## Trap

<!-- What looked right and wasn't. Fake-200, deleted-but-archived, upscale, wrapper. -->

## Enumeration surface

<!-- Open index / API endpoint / CDX query that lists everything. -->

## Dead ends (with disproving evidence)

<!-- e.g. /ko/ and /iyaz/: archived HTML only, {"archived_snapshots":{}} for every image. -->
EOF

say "done"
note "dossier:  $OUTDIR/RECON.md"
note "raw:      $OUTDIR/"
note "lore stub: $OUTDIR/registry-stub.md"
echo
sed -n '1,12p' "$OUTDIR/RECON.md"
