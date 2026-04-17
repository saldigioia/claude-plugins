#!/usr/bin/env bash
# Universal media downloader — probes any image/video/audio URL for the
# highest-quality downloadable format and fetches it.
#
# Image priority: TIF/TIFF > PNG (truecolor) > JPG/JPEG > PNG (palette) > WEBP
# Video priority: MP4 > WEBM > MOV (largest bitrate wins; Mux HLS via yt-dlp)
# Audio priority: FLAC > WAV > MP3 > AAC > OGG (largest bitrate wins)
#
# Pipeline per URL:
#   0. CDN resolution — rewrite URL to request original/largest version
#   1. HTTP Accept header content negotiation
#   2. CDN query-parameter probing (?fm=, ?format=, ?f=, ?output=)
#   3. URL path extension swapping
#   B. Baseline — whatever the original URL returns (always a fallback)
#
# Usage:
#   app.sh urls.txt                  # read URLs from file
#   app.sh url1 url2 ...             # URLs as arguments
#   cat urls.txt | app.sh            # read from stdin
#   app.sh -o ./my_output urls.txt   # custom output directory
#   app.sh --no-cdn url1             # skip CDN resolution
#   app.sh -c cookies.txt --vimeo 385365963          # Vimeo by ID
#   app.sh -c cookies.txt --vimeo https://vimeo.com/252387977
#   app.sh -c cookies.txt --vimeo https://example.com/page-with-embed
#
# Requirements: curl, aria2c
# Optional:     yt-dlp + ffmpeg (for Mux HLS full-quality downloads)
#               python3 (required with --vimeo for JWT/JSON parsing)
#               PROBE_DELAY env var (seconds between probe batches, default 0)

set -euo pipefail

# ── configuration ────────────────────────────────────────────────────────────

OUTDIR="downloads"
PROBE_DELAY="${PROBE_DELAY:-0}"
SIZE_DOMINANCE_RATIO="${SIZE_DOMINANCE_RATIO:-4}"
GENERIC_STRIP="${GENERIC_STRIP:-true}"
FORMAT_CACHE="${FORMAT_CACHE:-$HOME/.cdn_format_cache}"
NO_CDN=false
FORMAT_DISCOVER=""
VIMEO_REFERER=""
CUSTOM_FILENAME=""
VIMEO_MODE=false
COOKIES=""
JWT=""
JWT_EXPIRY=0
PREFER_SOURCE="${PREFER_SOURCE:-true}"
ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-16}"
FORCE_DOWNLOAD=false
TRUST_CDN=false
MIN_SIZE_MB=150
MIN_SIZE_BYTES=$(( MIN_SIZE_MB * 1024 * 1024 ))
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# format priority — lower = better (looked up via fmt_priority function)

# formats to probe, in priority order
PROBE_FMTS=( tif png jpg webp )

# CDN query-param patterns to try
PARAM_PATTERNS=( fm format f output )

# extensions to try when swapping paths
PATH_EXTS=( tif tiff png jpg jpeg )

# ── colors & logging (used by Vimeo pipeline) ──────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

vlog()  { printf "${CYAN}[info]${RESET}  %s\n" "$*"; }
vok()   { printf "${GREEN}[ok]${RESET}    %s\n" "$*"; }
vwarn() { printf "${YELLOW}[warn]${RESET}  %s\n" "$*" >&2; }
verr()  { printf "${RED}[error]${RESET} %s\n" "$*" >&2; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Parse Content-Type and Content-Length from raw HTTP headers.
# Follows redirects. Outputs two lines: content_type\ncontent_length
head_info() {
  local url="$1"; shift
  local extra_headers=("$@")
  local raw ct cl

  raw="$(curl -sI -L --max-time 10 -H "User-Agent: $UA" ${extra_headers[@]+"${extra_headers[@]}"} "$url" 2>/dev/null)"

  # Cloudflare managed challenge — TLS fingerprint block.
  # curl can never pass this; retry via curl_cffi (browser TLS impersonation).
  if is_cf_challenged "$raw" && $HAVE_CURL_CFFI; then
    echo "$url" >> "$CF_BYPASS_FILE"
    cffi_head_info "$url"
    return
  fi

  ct="$(printf '%s' "$raw" | grep -i '^content-type:' | tail -n1 | tr -d '\r' | awk '{print $2}' | tr -d ';')"
  cl="$(printf '%s' "$raw" | grep -i '^content-length:' | tail -n1 | tr -d '\r' | awk '{print $2}')"

  # Fall back to a GET probe when HEAD is unusable.  Two known cases:
  # 1. Hypebeast/CloudFront+Lambda: HEAD returns content-length: 0
  # 2. Cargo/CloudFront: HEAD returns 403 (text/html) while GET serves the image
  local need_get=false
  if [[ "${cl:-0}" == "0" && "${ct:-unknown}" != "unknown" ]]; then
    need_get=true
  elif [[ -z "$ct" || "$ct" == "unknown" || "$ct" == text/* ]]; then
    need_get=true
  fi
  if $need_get; then
    local get_out get_ct2 get_size
    get_out="$(curl -s -o /dev/null -L --max-time 15 -w '%{content_type}\n%{size_download}' \
      -H "User-Agent: $UA" ${extra_headers[@]+"${extra_headers[@]}"} "$url" 2>/dev/null)"
    get_ct2="$(sed -n '1p' <<< "$get_out" | awk -F';' '{print $1}')"
    get_size="$(sed -n '2p' <<< "$get_out")"
    if [[ "${get_size:-0}" != "0" ]]; then
      [[ -n "$get_ct2" ]] && ct="$get_ct2"
      cl="$get_size"
    fi
  fi

  printf '%s\n%s\n' "${ct:-unknown}" "${cl:-0}"
}

# Quick status code check.  Tries HEAD first; if the server returns 403/405
# (some CDNs block HEAD), retries with GET.
http_status() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -I -L --max-time 10 -H "User-Agent: $UA" "$1" 2>/dev/null)"
  if [[ "$code" == "403" || "$code" == "405" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 -H "User-Agent: $UA" "$1" 2>/dev/null)"
  fi
  echo "$code"
}

# Check if yt-dlp is available (for HLS downloads).
has_ytdlp() { command -v yt-dlp &>/dev/null; }
has_python3() { command -v python3 &>/dev/null; }

# Check if curl_cffi is available (for Cloudflare TLS fingerprint bypass).
has_curl_cffi() {
  python3 -c "import curl_cffi" &>/dev/null 2>&1
}

# Track whether curl_cffi is available (checked once at startup).
HAVE_CURL_CFFI=false

# File tracking URLs that required Cloudflare bypass (survives subshells).
CF_BYPASS_FILE="$(mktemp)"

# Detect Cloudflare managed challenge in raw HTTP headers.
is_cf_challenged() {
  printf '%s' "$1" | grep -qi 'cf-mitigated:.*challenge'
}

# Probe a URL using curl_cffi with browser TLS impersonation.
# Outputs two lines: content_type\ncontent_length (same as head_info).
cffi_head_info() {
  local url="$1"
  python3 -c "
import sys
from curl_cffi import requests
try:
    r = requests.head('$url', impersonate='firefox', timeout=15, allow_redirects=True)
    ct = r.headers.get('content-type', 'unknown').split(';')[0].strip()
    cl = r.headers.get('content-length', '0')
    # If HEAD returns no content-length or text/html, retry with GET
    if cl == '0' or ct.startswith('text/'):
        r = requests.get('$url', impersonate='firefox', timeout=15, allow_redirects=True)
        ct = r.headers.get('content-type', 'unknown').split(';')[0].strip()
        cl = str(len(r.content))
    print(ct)
    print(cl)
except Exception as e:
    print('unknown', file=sys.stderr)
    print('unknown')
    print('0')
" 2>/dev/null
}

# Download a file using curl_cffi with browser TLS impersonation.
# Args: url output_path
cffi_download() {
  local url="$1" output="$2"
  python3 -c "
import sys
from curl_cffi import requests
try:
    r = requests.get(sys.argv[1], impersonate='firefox', timeout=300, allow_redirects=True)
    if r.status_code == 200:
        with open(sys.argv[2], 'wb') as f:
            f.write(r.content)
        sys.exit(0)
    else:
        print(f'HTTP {r.status_code}', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$url" "$output"
}

# Map a Content-Type to a short format name, or "unknown".
ct_to_fmt() {
  case "$1" in
    image/tiff)               echo "tif"  ;;
    image/png)                echo "png"  ;;
    image/jpeg)               echo "jpg"  ;;
    image/webp)               echo "webp" ;;
    video/mp4)                echo "mp4"  ;;
    video/webm)               echo "webm" ;;
    video/quicktime)          echo "mov"  ;;
    audio/mpeg)               echo "mp3"  ;;
    audio/aac)                echo "aac"  ;;
    audio/flac)               echo "flac" ;;
    audio/wav|audio/x-wav)    echo "wav"  ;;
    audio/ogg)                echo "ogg"  ;;
    *)                        echo "unknown" ;;
  esac
}

# Return the numeric priority for a format (lower = better). Unknown = 99.
fmt_priority() {
  case "$1" in
    tif|tiff)     echo 1 ;;
    png)          echo 2 ;;
    jpg|jpeg)     echo 3 ;;
    png-indexed)  echo 4 ;;
    webp)         echo 5 ;;
    mp4)      echo 10 ;;
    webm)     echo 11 ;;
    mov)      echo 12 ;;
    flac)     echo 20 ;;
    wav)      echo 21 ;;
    mp3)      echo 22 ;;
    aac)      echo 23 ;;
    ogg)      echo 24 ;;
    *)        echo 99 ;;
  esac
}

# Verify actual format by fetching first 16 bytes and checking magic numbers.
# Returns the real format, or "unknown" if unrecognizable.
verify_magic() {
  local url="$1"
  local magic
  magic="$(curl -s -L --max-time 10 -r 0-15 "$url" 2>/dev/null | xxd -p -l 16)"

  case "$magic" in
    49492a00*)       echo "tif" ;;   # TIFF little-endian
    4d4d002a*)       echo "tif" ;;   # TIFF big-endian
    89504e47*)       echo "png" ;;   # PNG
    ffd8ff*)         echo "jpg" ;;   # JPEG
    52494646*)                        # RIFF — check for WEBP or WAV
      if [[ "$magic" == *"57454250"* ]]; then
        echo "webp"
      elif [[ "$magic" == *"57415645"* ]]; then
        echo "wav"
      else
        echo "unknown"
      fi
      ;;
    0000002066747970*|000000186674797066747970*|00000020667479706d703432*) echo "mp4" ;; # ftyp box (MP4)
    1a45dfa3*)       echo "webm" ;;  # EBML header (WebM/MKV)
    664c6143*)       echo "flac" ;;  # fLaC
    4f676753*)       echo "ogg"  ;;  # OggS
    fff1*|fff9*)     echo "aac"  ;;  # ADTS AAC
    fffb*|fff3*|49443303*) echo "mp3" ;; # MP3 / ID3
    *)
      # MP4 ftyp box can start at various offsets; check for 'ftyp' anywhere
      if [[ "$magic" == *"66747970"* ]]; then
        echo "mp4"
      # MP3 sync word can appear after ID3 tags
      elif [[ "$magic" == *"fffb"* ]] || [[ "$magic" == *"fff3"* ]]; then
        echo "mp3"
      else
        echo "unknown"
      fi
      ;;
  esac
}

# Check if a PNG is palette-indexed (color type 3 in IHDR at byte offset 25).
# Returns 0 if indexed, 1 if truecolor or check fails.
png_is_indexed() {
  local url="$1"
  local raw
  raw="$(curl -s -L --max-time 10 -r 24-25 "$url" 2>/dev/null | xxd -p -l 2)"
  [[ "${#raw}" -ge 4 ]] || return 1
  # byte 25 (second byte of this 2-byte fetch) is the color type
  local color_type="${raw:2:2}"
  [[ "$color_type" == "03" ]]
}

# Append a query parameter to a URL, handling existing '?' correctly.
append_param() {
  local url="$1" key="$2" val="$3"
  if [[ "$url" == *"?"* ]]; then
    echo "${url}&${key}=${val}"
  else
    echo "${url}?${key}=${val}"
  fi
}

# Remove specific query parameters from a URL by key name.
strip_url_params() {
  local url="$1"; shift
  local params_to_strip=("$@")

  local base="${url%%\?*}"
  [[ "$url" == *"?"* ]] || { echo "$url"; return; }
  local query="${url#*\?}"

  local new_query="" key param
  while IFS= read -r -d '&' param || [[ -n "$param" ]]; do
    key="${param%%=*}"
    local strip=false
    for s in "${params_to_strip[@]}"; do
      if [[ "$key" == "$s" ]]; then strip=true; break; fi
    done
    if ! $strip; then
      [[ -n "$new_query" ]] && new_query="${new_query}&"
      new_query="${new_query}${param}"
    fi
  done <<< "$query"

  if [[ -n "$new_query" ]]; then
    echo "${base}?${new_query}"
  else
    echo "$base"
  fi
}

# Derive output filename stem from URL path.
basename_from_url() {
  local url="$1"
  local base="${url%%\?*}"
  base="${base##*/}"
  # strip any existing media extension — we'll add the correct one
  base="${base%.[tT][iI][fF]}"
  base="${base%.[tT][iI][fF][fF]}"
  base="${base%.[pP][nN][gG]}"
  base="${base%.[jJ][pP][gG]}"
  base="${base%.[jJ][pP][eE][gG]}"
  base="${base%.[wW][eE][bB][pP]}"
  base="${base%.[mM][pP]4}"
  base="${base%.[wW][eE][bB][mM]}"
  base="${base%.[mM][oO][vV]}"
  base="${base%.[mM][pP]3}"
  base="${base%.[aA][aA][cC]}"
  base="${base%.[fF][lL][aA][cC]}"
  base="${base%.[wW][aA][vV]}"
  base="${base%.[oO][gG][gG]}"
  base="${base%.[mM]3[uU]8}"
  # fallback if nothing remains
  [[ -z "$base" ]] && base="media_$(date +%s%N)"
  echo "$base"
}

# ── Vimeo pipeline (active when --vimeo flag is set) ────────────────────────

# Check if a file size meets the minimum threshold.
# Returns 0 if download should proceed, 1 if it should be skipped.
check_min_size() {
    local size_bytes="$1"
    local label="$2"

    if [[ "$FORCE_DOWNLOAD" == "true" ]]; then
        return 0
    fi

    if [[ "$size_bytes" -gt 0 ]] && [[ "$size_bytes" -lt "$MIN_SIZE_BYTES" ]]; then
        local size_mb
        size_mb=$(python3 -c "print(f'{${size_bytes}/1024/1024:.1f}')" 2>/dev/null || echo "?")
        vwarn "Skipping ${label} — ${size_mb} MB is below ${MIN_SIZE_MB} MB minimum (use --force-download to override)"
        return 1
    fi

    return 0
}

# Returns "vimeo" for direct Vimeo URLs, "embed" for third-party pages
vimeo_classify_url() {
    local url="$1"
    if echo "$url" | grep -qE '(^https?://)?(www\.)?(vimeo\.com|player\.vimeo\.com)/'; then
        echo "vimeo"
    else
        echo "embed"
    fi
}

# Extract video ID from a direct Vimeo URL
vimeo_extract_id() {
    local url="$1"
    echo "$url" | grep -oE '[0-9]{6,}' | head -1
}

# Extract unlisted hash from a Vimeo URL like /video_id/hash
vimeo_extract_hash() {
    local url="$1"
    local hash
    hash=$(echo "$url" | grep -oE 'vimeo\.com/[0-9]+/([a-f0-9]{8,})' | grep -oE '/[a-f0-9]{8,}$' | tr -d '/')
    echo "$hash"
}

# Scrape a third-party page for embedded Vimeo video IDs.
# Returns lines of: video_id|referer_origin
vimeo_scrape_embed_ids() {
    local page_url="$1"
    local origin
    origin=$(echo "$page_url" | grep -oE 'https?://[^/]+')

    # Fetch page — try with cookies first (some sites require auth/session)
    local html
    if [[ -n "$COOKIES" ]] && [[ -f "$COOKIES" ]]; then
        html=$(curl -sL "$page_url" -b "$COOKIES" -H "User-Agent: $UA" 2>/dev/null)
    fi
    # Fall back to no cookies if empty or if cookies weren't used
    if [[ -z "$html" ]]; then
        html=$(curl -sL "$page_url" -H "User-Agent: $UA" 2>/dev/null)
    fi

    # Strategy 1: direct iframe src in HTML
    local ids
    ids=$(echo "$html" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)

    # Strategy 2: data-vimeo-id or data-video-id attributes
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'data-vimeo-id="[0-9]+"' | grep -oE '[0-9]+' | sort -u)
    fi
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'data-video-id="[0-9]+"' | grep -oE '[0-9]+' | sort -u)
    fi

    # Strategy 3: Vimeo IDs in inline JSON/script blocks
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE '"(vimeo_?[Ii]d|video_?[Ii]d|externalId|vimeoVideo)"[[:space:]]*:[[:space:]]*"?[0-9]{6,}"?' \
            | grep -oE '[0-9]{6,}' | sort -u)
    fi

    # Strategy 4: Vimeo player embed URLs in JavaScript strings (escaped or unescaped)
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'player\.vimeo\.com\\?/video\\?/[0-9]+' | grep -oE '[0-9]{6,}' | sort -u)
    fi

    # Strategy 5: Squarespace ?format=json API
    if [[ -z "$ids" ]]; then
        local base_url="${page_url%%#*}"
        local json_html
        json_html=$(curl -sL "${base_url}?format=json" -H "User-Agent: $UA" 2>/dev/null)
        ids=$(echo "$json_html" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)
        if [[ -z "$ids" ]]; then
            ids=$(echo "$json_html" | grep -oE '"(vimeoId|externalId|videoId)"[[:space:]]*:[[:space:]]*"?[0-9]{6,}"?' \
                | grep -oE '[0-9]{6,}' | sort -u)
        fi
    fi

    # Strategy 6: look for vimeo.com/{id} patterns in page data
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'vimeo\.com/[0-9]{6,}' | grep -oE '[0-9]+' | sort -u)
    fi

    # Strategy 7: for SPAs with hash routes, try the page path as a slug
    if [[ -z "$ids" ]] && echo "$page_url" | grep -q '#/'; then
        local slug
        slug=$(echo "$page_url" | sed 's/.*#\///' | sed 's/\/$//')
        local slug_url="${page_url%%#*}${slug}/?format=json"
        local slug_json
        slug_json=$(curl -sL "$slug_url" -H "User-Agent: $UA" 2>/dev/null)
        ids=$(echo "$slug_json" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)
    fi

    # Strategy 8: query param hints — try common CMS API patterns
    if [[ -z "$ids" ]]; then
        local api_paths=()
        local path_part
        path_part=$(echo "$page_url" | sed 's|https\?://[^/]*||')
        api_paths+=("${origin}/api${path_part}")
        api_paths+=("${origin}/api/v1${path_part}")
        for api_url in "${api_paths[@]}"; do
            local api_resp
            api_resp=$(curl -sL "$api_url" -H "User-Agent: $UA" -H "Accept: application/json" 2>/dev/null)
            ids=$(echo "$api_resp" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)
            if [[ -z "$ids" ]]; then
                ids=$(echo "$api_resp" | grep -oE '"(vimeo_?[Ii]d|video_?[Ii]d|externalId)"[[:space:]]*:[[:space:]]*"?[0-9]{6,}"?' \
                    | grep -oE '[0-9]{6,}' | sort -u)
            fi
            if [[ -z "$ids" ]]; then
                ids=$(echo "$api_resp" | grep -oE 'vimeo\.com/[0-9]{6,}' | grep -oE '[0-9]+' | sort -u)
            fi
            [[ -n "$ids" ]] && break
        done
    fi

    if [[ -z "$ids" ]]; then
        return 1
    fi

    local vid
    for vid in $ids; do
        echo "${vid}|${origin}"
    done
}

# ── Vimeo JWT management ────────────────────────────────────────────────────

vimeo_refresh_jwt() {
    local now
    now=$(date +%s)

    if [[ -n "$JWT" ]] && (( JWT_EXPIRY > now + 120 )); then
        return 0
    fi

    vlog "Acquiring JWT token..."
    local viewer_json
    viewer_json=$(curl -s -b "$COOKIES" \
        -H "Accept: application/json" \
        -H "User-Agent: $UA" \
        "https://vimeo.com/_next/viewer" 2>/dev/null)

    JWT=$(echo "$viewer_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jwt',''))" 2>/dev/null)

    if [[ -z "$JWT" ]]; then
        verr "Failed to acquire JWT. Check your cookies file."
        return 1
    fi

    JWT_EXPIRY=$(echo "$JWT" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
print(d.get('exp', 0))
" 2>/dev/null)

    vok "JWT acquired (expires $(date -r "$JWT_EXPIRY" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$JWT_EXPIRY"))"
}

# ── Vimeo API path ──────────────────────────────────────────────────────────

vimeo_fetch_info() {
    local video_id="$1"
    local unlisted_hash="${2:-}"
    local api_id="$video_id"
    if [[ -n "$unlisted_hash" ]]; then
        api_id="${video_id}:${unlisted_hash}"
    fi
    curl -s \
        -H "Authorization: jwt $JWT" \
        -H "Accept: application/vnd.vimeo.*+json;version=3.4.10" \
        -H "User-Agent: $UA" \
        "https://api.vimeo.com/videos/${api_id}?fields=name,duration,download,files,pictures.base_link" \
        2>/dev/null
}

vimeo_select_best() {
    python3 -c "
import sys, json, urllib.parse

d = json.load(sys.stdin)
name = d.get('name', 'video')
downloads = d.get('download', [])

if not downloads:
    print('ERROR: No download links available')
    sys.exit(1)

source = None
best_transcode = None

for f in downloads:
    q = f.get('quality', '')
    r = f.get('rendition', '')
    if q == 'source' or r == 'source':
        source = f
    else:
        try:
            h = int(r.replace('p',''))
        except:
            h = 0
        if best_transcode is None or h > best_transcode.get('_h', 0):
            f['_h'] = h
            best_transcode = f

prefer_source = '$PREFER_SOURCE' == 'true'

chosen = None
if prefer_source and source:
    chosen = source
elif best_transcode:
    chosen = best_transcode
elif source:
    chosen = source
else:
    chosen = downloads[0]

url = chosen.get('link', '')
quality = chosen.get('quality', '?')
rendition = chosen.get('rendition', '?')
size = chosen.get('size', 0)
w = chosen.get('width', '?')
h = chosen.get('height', '?')

url_path = urllib.parse.urlparse(url).path
url_filename = urllib.parse.unquote(url_path.split('/')[-1])
if not url_filename or url_filename == '':
    url_filename = name.replace(' ', '_') + '.mp4'

print(url)
print(url_filename)
print(f'{quality} ({rendition}) {w}x{h}')
print(size)
" 2>/dev/null
}

# ── Vimeo player config path (embed-restricted videos) ──────────────────────

vimeo_fetch_player_config() {
    local video_id="$1"
    local referer="$2"

    curl -s "https://player.vimeo.com/video/${video_id}" \
        -H "Referer: ${referer}/" \
        -H "User-Agent: $UA" \
        2>/dev/null \
    | python3 -c "
import sys, json

html = sys.stdin.read()
marker = 'window.playerConfig = '
start = html.find(marker)
if start == -1:
    json.dump({'error': 'playerConfig not found in page'}, sys.stdout)
    sys.exit(0)

start += len(marker)
depth = 0
in_string = False
escape = False
end = start
for i, ch in enumerate(html[start:], start):
    if escape:
        escape = False
        continue
    if ch == '\\\\' and in_string:
        escape = True
        continue
    if ch == '\"' and not escape:
        in_string = not in_string
        continue
    if in_string:
        continue
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break

json.dump(json.loads(html[start:end]), sys.stdout)
" 2>/dev/null
}

vimeo_download_via_ytdlp() {
    local video_id="$1"
    local referer="$2"

    mkdir -p "$OUTDIR"

    yt-dlp \
        --cookies "$COOKIES" \
        --referer "$referer" \
        -f "bestvideo+bestaudio/best" \
        --merge-output-format mp4 \
        -o "${OUTDIR}/%(title)s.%(ext)s" \
        --no-overwrites \
        --no-warnings \
        --progress \
        "https://player.vimeo.com/video/${video_id}"

    return $?
}

# ── Vimeo download helper ───────────────────────────────────────────────────

vimeo_download_file() {
    local url="$1"
    local filename="$2"
    local outdir="$3"
    local expected_size="$4"

    # Sanitize filename: replace $ with S (aria2c and shells choke on it)
    filename="${filename//\$/S}"

    local filepath="${outdir}/${filename}"

    if [[ -f "$filepath" ]]; then
        local local_size
        local_size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
        if [[ "$expected_size" -gt 0 ]] && [[ "$local_size" -eq "$expected_size" ]]; then
            vok "Already downloaded: $filename ($local_size bytes)"
            return 0
        fi
    fi

    # Vimeo's progressive_redirect download URLs return 302 with empty Location
    # and Content-Length: 0 — the link is non-functional for direct HTTP clients.
    # We still attempt the download, but verify the result.  If it fails (0 bytes),
    # return 1 so the caller can fall back to player config / yt-dlp.
    local encoded_url
    encoded_url=$(python3 -c "
import sys, urllib.parse
url = sys.stdin.read().strip()
p = urllib.parse.urlparse(url)
safe_path = urllib.parse.quote(urllib.parse.unquote(p.path), safe='/:@!&=+,;')
print(urllib.parse.urlunparse((p.scheme, p.netloc, safe_path, p.params, p.query, p.fragment)))
" <<< "$url")

    # Try aria2c first (fast, multi-connection)
    if aria2c \
        -x "$ARIA2_CONNECTIONS" \
        -s "$ARIA2_CONNECTIONS" \
        -k 1M \
        --file-allocation=none \
        --auto-file-renaming=false \
        --allow-overwrite=true \
        --header="Referer: https://vimeo.com/" \
        --header="User-Agent: $UA" \
        --load-cookies="$COOKIES" \
        -d "$outdir" \
        -o "$filename" \
        "$encoded_url" >/dev/null 2>&1; then
        # Verify aria2c actually wrote data
        local a2_size
        a2_size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
        if [[ "$a2_size" -gt 0 ]]; then
            return 0
        fi
    fi

    # aria2c failed or wrote 0 bytes — try curl
    rm -f "$filepath"
    curl -fL -# \
        -o "${filepath}" \
        -H "User-Agent: $UA" \
        -H "Referer: https://vimeo.com/" \
        -b "$COOKIES" \
        "$url" 2>/dev/null

    # Verify curl actually wrote data
    local dl_size
    dl_size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
    if [[ "$dl_size" -eq 0 ]]; then
        rm -f "$filepath"
        return 1
    fi
}

# ── Vimeo process: API path ─────────────────────────────────────────────────

vimeo_process_api() {
    local video_id="$1"
    local unlisted_hash="${2:-}"

    vimeo_refresh_jwt || return 1

    local api_json
    api_json=$(vimeo_fetch_info "$video_id" "$unlisted_hash")

    # Check for API error
    local api_error
    api_error=$(echo "$api_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        print(d.get('developer_message', d.get('error_code', d['error'])))
    elif not d.get('download') and not d.get('files'):
        print('No download/files fields in response')
except Exception as e:
    print(f'Failed to parse API response: {e}')
" 2>/dev/null)

    if [[ -n "$api_error" ]]; then
        verr "API error for video $video_id: $api_error"
        return 1
    fi

    local title
    title=$(echo "$api_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','Unknown'))" 2>/dev/null)
    printf "${CYAN}[info]${RESET}  Title: ${BOLD}%s${RESET}\n" "$title"

    # List renditions
    echo "$api_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
downloads = d.get('download', [])
if not downloads:
    print('  (no downloads available)')
else:
    for f in downloads:
        q = f.get('quality','?')
        r = f.get('rendition','?')
        w = f.get('width','?')
        h = f.get('height','?')
        s = f.get('size',0)
        mb = f'{s/1024/1024:.1f}MB' if s else '?'
        marker = ' ◄' if q == 'source' else ''
        print(f'  {q:>8s} {r:>8s}  {w}x{h}  {mb}{marker}')
" 2>/dev/null

    local download_info
    download_info=$(echo "$api_json" | vimeo_select_best)

    if echo "$download_info" | grep -q "^ERROR:"; then
        verr "$download_info"
        return 1
    fi

    local dl_url dl_filename dl_quality dl_size
    dl_url=$(echo "$download_info" | sed -n '1p')
    dl_filename=$(echo "$download_info" | sed -n '2p')
    dl_quality=$(echo "$download_info" | sed -n '3p')
    dl_size=$(echo "$download_info" | sed -n '4p')

    local size_mb
    size_mb=$(python3 -c "print(f'{$dl_size/1024/1024:.1f}MB')" 2>/dev/null || echo "?")

    printf "${CYAN}[info]${RESET}  Selected: ${GREEN}%s${RESET}  %s  →  %s\n" "$dl_quality" "$size_mb" "$dl_filename"

    check_min_size "$dl_size" "$dl_filename" || return 0

    mkdir -p "$OUTDIR"
    vimeo_download_file "$dl_url" "$dl_filename" "$OUTDIR" "$dl_size"

    if [[ $? -eq 0 ]]; then
        vok "Downloaded: ${OUTDIR}/${dl_filename}"
    else
        verr "Download failed: $dl_filename"
        return 1
    fi
}

# ── Vimeo process: player config path (embed-restricted) ────────────────────

vimeo_process_player() {
    local video_id="$1"
    local referer="$2"

    vlog "Using player config path (Referer: $referer)"

    local config_json
    config_json=$(vimeo_fetch_player_config "$video_id" "$referer")

    local title="Unknown"
    if echo "$config_json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
        title=$(echo "$config_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('video',{}).get('title','Unknown'))" 2>/dev/null)
    fi
    printf "${CYAN}[info]${RESET}  Title: ${BOLD}%s${RESET}\n" "$title"

    # Check for progressive downloads first
    local prog_count
    prog_count=$(echo "$config_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
prog = d.get('request',{}).get('files',{}).get('progressive',[])
print(len(prog))
" 2>/dev/null || echo "0")

    if [[ "$prog_count" -gt 0 ]]; then
        vlog "Progressive MP4s available ($prog_count)"

        local prog_info
        prog_info=$(echo "$config_json" | python3 -c "
import sys, json, urllib.parse
d = json.load(sys.stdin)
prog = d.get('request',{}).get('files',{}).get('progressive',[])
title = d.get('video',{}).get('title','video')

best = max(prog, key=lambda p: p.get('height', 0))
url = best.get('url', '')
w = best.get('width', '?')
h = best.get('height', '?')
quality = best.get('quality', '?')

safe_title = ''.join(c if c.isalnum() or c in '._-' else '_' for c in title)
safe_title = '_'.join(filter(None, safe_title.split('_')))
filename = f'{safe_title}.mp4'

print(url)
print(filename)
print(f'{quality} {w}x{h}')
print(0)
" 2>/dev/null)

        local dl_url dl_filename dl_quality
        dl_url=$(echo "$prog_info" | sed -n '1p')
        dl_filename=$(echo "$prog_info" | sed -n '2p')
        dl_quality=$(echo "$prog_info" | sed -n '3p')

        # HEAD request to get actual file size for progressive downloads
        local prog_size=0
        prog_size=$(curl -sI -L "$dl_url" -H "User-Agent: $UA" 2>/dev/null \
            | grep -i '^content-length:' | tail -1 | tr -dc '0-9')
        prog_size="${prog_size:-0}"

        local prog_size_mb
        prog_size_mb=$(python3 -c "print(f'{${prog_size}/1024/1024:.1f}')" 2>/dev/null || echo "?")
        printf "${CYAN}[info]${RESET}  Selected: ${GREEN}%s${RESET}  %sMB  →  %s\n" "$dl_quality" "$prog_size_mb" "$dl_filename"

        check_min_size "$prog_size" "$dl_filename" || return 0

        mkdir -p "$OUTDIR"
        vimeo_download_file "$dl_url" "$dl_filename" "$OUTDIR" "$prog_size"
        vok "Downloaded: ${OUTDIR}/${dl_filename}"
    else
        # Use yt-dlp for HLS/DASH download
        if [[ "$FORCE_DOWNLOAD" != "true" ]]; then
            local est_size
            est_size=$(yt-dlp \
                --cookies "$COOKIES" \
                --referer "$referer" \
                -f "bestvideo+bestaudio/best" \
                --print "%(filesize_approx)s" \
                --no-warnings \
                "https://player.vimeo.com/video/${video_id}" 2>/dev/null)
            est_size="${est_size:-0}"
            if [[ "$est_size" != "NA" ]] && [[ "$est_size" =~ ^[0-9]+$ ]]; then
                check_min_size "$est_size" "$title" || return 0
            fi
        fi

        vlog "No progressive MP4s — downloading via yt-dlp (best HLS/DASH)"
        vimeo_download_via_ytdlp "$video_id" "$referer"
    fi
}

# ── Vimeo process: unified entry point ──────────────────────────────────────

vimeo_process_url() {
    local url="$1"
    local url_type
    url_type=$(vimeo_classify_url "$url")

    if [[ "$url_type" == "vimeo" ]]; then
        # Direct Vimeo URL
        local video_id
        video_id=$(vimeo_extract_id "$url")
        if [[ -z "$video_id" ]]; then
            verr "Could not extract video ID from: $url"
            return 1
        fi
        local unlisted_hash
        unlisted_hash=$(vimeo_extract_hash "$url")
        printf "${CYAN}[info]${RESET}  Processing video ${BOLD}%s${RESET} ...\n" "$video_id"
        if ! vimeo_process_api "$video_id" "$unlisted_hash"; then
            # API failed — fall back to player config path
            local referer
            if echo "$url" | grep -q 'player\.vimeo\.com'; then
                referer="https://vimeo.com"
            else
                referer=$(echo "$url" | grep -oE 'https?://[^/]+')
            fi
            vwarn "API path failed — trying player config / yt-dlp fallback"
            vimeo_process_player "$video_id" "$referer"
        fi

    elif [[ "$url_type" == "embed" ]]; then
        # Third-party page with embedded Vimeo
        printf "${CYAN}[info]${RESET}  Scraping embed page: ${BOLD}%s${RESET}\n" "$url"

        local embed_data
        embed_data=$(vimeo_scrape_embed_ids "$url")

        if [[ -z "$embed_data" ]]; then
            verr "No Vimeo embeds found on: $url"
            return 1
        fi

        local line video_id referer found_count=0
        while IFS='|' read -r video_id referer; do
            ((found_count++))
            printf "${CYAN}[info]${RESET}  Found embedded video ${BOLD}%s${RESET}\n" "$video_id"

            # Try API path first (works for public/unlisted videos)
            if vimeo_process_api "$video_id" 2>/dev/null; then
                continue
            fi

            # Fall back to player config path
            vwarn "API unavailable for $video_id — trying player config path"
            vimeo_process_player "$video_id" "$referer"

        done <<< "$embed_data"

        if [[ "$found_count" -eq 0 ]]; then
            verr "No Vimeo embeds found on: $url"
            return 1
        fi
    fi
}

# ── CDN resolution ───────────────────────────────────────────────────────────
# Each cdn_resolve_*() takes a URL, echoes the rewritten URL if the CDN is
# detected, or returns 1.  Pure string manipulation except where noted.

# -- helpers for CDN detection ------------------------------------------------

# Check if a Cloudinary path segment is a transform.
_is_cloudinary_transform() {
  local seg="$1"
  [[ "$seg" == *","* ]] && return 0          # multi-transform (w_800,h_600)
  [[ "$seg" == s--* ]] && return 0           # signed URL
  case "$seg" in
    w_*|h_*|c_*|f_*|q_*|g_*|e_*|l_*|o_*|r_*|t_*|x_*|y_*|z_*) return 0 ;;
    ar_*|bo_*|co_*|dl_*|dn_*|du_*|dpr_*|fl_*|fn_*|if_*|ki_*|pg_*|sp_*|so_*|vc_*) return 0 ;;
  esac
  return 1
}

# -- Category E: Proxy CDNs (extract original URL) ---------------------------

cdn_resolve_nextjs() {
  local url="$1"
  [[ "$url" == *"/_next/image?"* ]] || return 1

  local encoded
  encoded="$(echo "$url" | sed -n 's/.*[?&]url=\([^&]*\).*/\1/p')"
  [[ -n "$encoded" ]] || return 1

  local decoded
  decoded="$(printf '%b' "${encoded//%/\\x}")"

  if [[ "$decoded" == /* ]]; then
    local origin
    origin="$(echo "$url" | sed -E 's|(https?://[^/]+).*|\1|')"
    echo "${origin}${decoded}"
  else
    echo "$decoded"
  fi
}

cdn_resolve_netlify() {
  local url="$1"
  [[ "$url" == *"/.netlify/images?"* ]] || return 1

  local encoded
  encoded="$(echo "$url" | sed -n 's/.*[?&]url=\([^&]*\).*/\1/p')"
  [[ -n "$encoded" ]] || return 1

  local decoded
  decoded="$(printf '%b' "${encoded//%/\\x}")"

  if [[ "$decoded" == /* ]]; then
    local origin
    origin="$(echo "$url" | sed -E 's|(https?://[^/]+).*|\1|')"
    echo "${origin}${decoded}"
  else
    echo "$decoded"
  fi
}

cdn_resolve_wp_photon() {
  local url="$1"
  [[ "$url" =~ i[0-9]\.wp\.com ]] || return 1

  local path_part="${url#*wp.com/}"
  path_part="${path_part%%\?*}"
  echo "https://${path_part}"
}

# Parse image metadata from a partial range request via file(1).
# Outputs three lines:
#   1. display dimensions  (WxH from JPEG SOF / PNG IHDR)
#   2. EXIF original dims  (WxH from embedded TIFF data, or "none")
#   3. raw file(1) output  (for further inspection)
_image_meta() {
  local url="$1"
  local info display_dims exif_w exif_h
  info="$(curl -sL -r 0-32767 --max-time 10 "$url" 2>/dev/null | file -b - 2>/dev/null)" || return 1

  # display dimensions: "precision N, WxH" in JPEG, or WxH in PNG header
  display_dims="$(echo "$info" | grep -oE 'precision [0-9]+, [0-9]+x[0-9]+' | head -1 \
    | grep -oE '[0-9]+x[0-9]+$')" || true
  if [[ -z "$display_dims" ]]; then
    display_dims="$(echo "$info" | grep -oE '[0-9]+x[0-9]+' \
      | awk -F'x' '$1>100 && $2>100' | tail -1)" || true
  fi
  [[ -n "$display_dims" ]] || return 1

  # EXIF original dimensions: "height=N" and "width=N" from TIFF metadata
  exif_w="$(echo "$info" | grep -oE 'width=[0-9]+' | head -1 | grep -oE '[0-9]+')" || true
  exif_h="$(echo "$info" | grep -oE 'height=[0-9]+' | head -1 | grep -oE '[0-9]+')" || true

  printf '%s\n' "$display_dims"
  if [[ -n "$exif_w" && -n "$exif_h" ]]; then
    printf '%s\n' "${exif_w}x${exif_h}"
  else
    printf 'none\n'
  fi
  printf '%s\n' "$info"
}

# Extract pixel dimensions (WxH) from an image URL.
# PNG: reads IHDR directly (fast, one small range request).
# JPEG/WebP/TIFF: uses _image_meta() with file(1) on a 32KB range.
# Returns dimension string (e.g. "1920x1080") or fails with return 1.
_image_dims() {
  local url="$1" fmt="${2:-}"

  case "$fmt" in
    png|png-indexed)
      # PNG IHDR: width at bytes 16-19, height at bytes 20-23 (big-endian)
      local raw w h
      raw="$(curl -s -L --max-time 10 -r 0-31 "$url" 2>/dev/null | xxd -p -l 32 | tr -d '\n')"
      [[ "${#raw}" -ge 48 ]] || return 1
      [[ "${raw:0:16}" == "89504e470d0a1a0a" ]] || return 1
      w=$(( 16#${raw:32:8} ))
      h=$(( 16#${raw:40:8} ))
      (( w > 0 && h > 0 )) || return 1
      echo "${w}x${h}"
      ;;
    *)
      # JPEG/WebP/TIFF: use file(1) on a 32KB range request
      local info dims
      info="$(curl -sL -r 0-32767 --max-time 10 "$url" 2>/dev/null | file -b - 2>/dev/null)" || return 1
      # try "precision N, WxH" (JPEG SOF marker)
      dims="$(echo "$info" | grep -oE 'precision [0-9]+, [0-9]+x[0-9]+' | head -1 \
        | grep -oE '[0-9]+x[0-9]+$')" || true
      # try "WxH" without spaces (WebP, some file(1) versions)
      if [[ -z "$dims" ]]; then
        dims="$(echo "$info" | grep -oE '[0-9]+x[0-9]+' \
          | awk -F'x' '$1>100 && $2>100' | tail -1)" || true
      fi
      # try "W x H" with spaces (PNG on macOS file(1))
      if [[ -z "$dims" ]]; then
        dims="$(echo "$info" | grep -oE '[0-9]+ x [0-9]+' \
          | awk -F' x ' '$1+0>100 && $2+0>100' | tail -1 | tr -d ' ')" || true
      fi
      [[ -n "$dims" ]] || return 1
      echo "$dims"
      ;;
  esac
}

# Check whether a collision-stripped candidate is the same image as the
# original (suffixed) URL.
#
# Strategy: when WordPress resizes a large upload to 2000px, the EXIF
# data in the resized file preserves the original sensor dimensions.
# If those EXIF dims match the candidate's actual display dims, the
# candidate IS the pre-resize original.  If they don't match, the
# candidate is a different photo that collided in the same YYYY/MM dir.
#
# Fallback: when EXIF data is absent from both, compare aspect ratios
# (within 5%).  This is weaker — common ratios like 4:3 can false-
# positive — but still better than blind acceptance.
_same_image() {
  local orig_url="$1" candidate_url="$2"
  local orig_meta cand_meta
  local orig_display orig_exif cand_display cand_exif

  orig_meta="$(_image_meta "$orig_url")" || return 1
  cand_meta="$(_image_meta "$candidate_url")" || return 1

  orig_display="$(sed -n '1p' <<< "$orig_meta")"
  orig_exif="$(sed -n '2p' <<< "$orig_meta")"
  cand_display="$(sed -n '1p' <<< "$cand_meta")"
  cand_exif="$(sed -n '2p' <<< "$cand_meta")"

  # Best signal: EXIF original dims in the suffixed file should match the
  # candidate's display dims (the candidate IS that original).
  if [[ "$orig_exif" != "none" ]]; then
    if [[ "$orig_exif" == "$cand_display" ]]; then
      return 0   # confirmed same image
    fi
    # EXIF present but doesn't match → definitely different image
    return 1
  fi

  # Second-best: if the candidate has EXIF and it matches the orig display,
  # the orig might be the larger version (unlikely for collision, but safe).
  if [[ "$cand_exif" != "none" ]]; then
    if [[ "$cand_exif" == "$orig_display" ]]; then
      return 0
    fi
    return 1
  fi

  # Fallback: neither has EXIF. Compare aspect ratios (weak signal).
  local ow oh cw ch o_aspect c_aspect diff threshold
  ow="${orig_display%x*}"; oh="${orig_display#*x}"
  cw="${cand_display%x*}"; ch="${cand_display#*x}"
  [[ "$oh" -gt 0 && "$ch" -gt 0 ]] 2>/dev/null || return 1
  o_aspect=$(( ow * 1000 / oh ))
  c_aspect=$(( cw * 1000 / ch ))
  diff=$(( o_aspect - c_aspect ))
  [[ $diff -lt 0 ]] && diff=$(( -diff ))
  threshold=$(( o_aspect / 20 ))
  [[ $threshold -lt 1 ]] && threshold=1
  (( diff <= threshold ))
}

cdn_resolve_wp_uploads() {
  local url="$1"
  [[ "$url" == *"wp-content/uploads/"* ]] || return 1

  local base_url="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  # must have an image extension
  echo "$base_url" | grep -qiE '\.(jpe?g|png|gif|webp|tiff?)$' || return 1

  local ext="${base_url##*.}"
  local dir="${base_url%/*}"
  local filename="${base_url##*/}"
  local stem="${filename%.*}"

  # Build candidate stems by progressively stripping WordPress suffixes.
  # Order matters: dimensions outermost, then -scaled, then collision.
  #   e.g. 7-1-scaled-500x375.jpg → 7-1-scaled → 7-1 → 7
  #
  # -WxH and -scaled are SAFE: WordPress generates them from the same upload.
  # Collision suffixes (-N) are UNSAFE: the file without -N may be a
  # completely different image that happened to collide in the same YYYY/MM
  # directory. Those candidates require aspect-ratio verification.

  local safe_candidates=()
  local collision_candidates=()
  local current="$stem"

  # 1. Strip dimensional thumbnail suffix  (-WxH)
  local stripped
  stripped="$(echo "$current" | sed -E 's/-[0-9]+x[0-9]+$//')"
  if [[ "$stripped" != "$current" ]]; then
    safe_candidates+=("$stripped")
    current="$stripped"
  fi

  # 2. Strip -scaled  (WP ≥5.3 big-image threshold)
  if [[ "$current" == *-scaled ]]; then
    current="${current%-scaled}"
    safe_candidates+=("$current")
  fi

  # 3. Strip collision suffix  (-N, single digit — WP duplicate-name rename)
  stripped="$(echo "$current" | sed -E 's/-([0-9])$//')"
  if [[ "$stripped" != "$current" ]]; then
    collision_candidates+=("$stripped")
  fi

  (( ${#safe_candidates[@]} + ${#collision_candidates[@]} == 0 )) && return 1

  # HEAD-check each candidate; return the largest valid one
  local best_url="" best_size=0
  local seen=""

  # Process safe candidates (no verification needed)
  for c in ${safe_candidates[@]+"${safe_candidates[@]}"}; do
    local candidate_url="${dir}/${c}.${ext}${query}"
    [[ "$candidate_url" == "$url" ]] && continue
    [[ "$seen" == *"|$c|"* ]] && continue
    seen="${seen}|$c|"

    local status
    status="$(http_status "$candidate_url")"
    [[ "$status" == 2* ]] || continue

    local info cl
    info="$(head_info "$candidate_url")"
    cl="$(sed -n '2p' <<< "$info")"
    cl="${cl:-0}"

    if (( cl > best_size )); then
      best_size="$cl"
      best_url="$candidate_url"
    fi
  done

  # Process collision candidates (aspect-ratio verification required)
  for c in ${collision_candidates[@]+"${collision_candidates[@]}"}; do
    local candidate_url="${dir}/${c}.${ext}${query}"
    [[ "$candidate_url" == "$url" ]] && continue
    [[ "$seen" == *"|$c|"* ]] && continue
    seen="${seen}|$c|"

    local status
    status="$(http_status "$candidate_url")"
    [[ "$status" == 2* ]] || continue

    # Verify this is the same image, not a different photo that collided
    if ! _same_image "$url" "$candidate_url"; then
      continue
    fi

    local info cl
    info="$(head_info "$candidate_url")"
    cl="$(sed -n '2p' <<< "$info")"
    cl="${cl:-0}"

    if (( cl > best_size )); then
      best_size="$cl"
      best_url="$candidate_url"
    fi
  done

  [[ -n "$best_url" ]] || return 1
  echo "$best_url"
}

cdn_resolve_cloudflare_images() {
  local url="$1"
  [[ "$url" == *"/cdn-cgi/image/"* ]] || return 1

  local after="${url#*/cdn-cgi/image/}"
  # skip options segment (everything before the next /)
  after="${after#*/}"

  if [[ "$after" == http* ]]; then
    echo "$after"
  else
    local origin
    origin="$(echo "$url" | sed -E 's|(https?://[^/]+).*|\1|')"
    echo "${origin}/${after}"
  fi
}

cdn_resolve_thumbor() {
  local url="$1"
  [[ "$url" == *"/unsafe/"* ]] || return 1

  local after="${url#*/unsafe/}"

  # look for embedded full URL
  if [[ "$after" == *"https://"* ]]; then
    echo "https://${after#*https://}"
    return 0
  elif [[ "$after" == *"http://"* ]]; then
    echo "http://${after#*http://}"
    return 0
  fi

  return 1
}

cdn_resolve_format() {
  local url="$1"
  [[ "$url" == *"creatorcdn.com/"* ]] || return 1

  local uuids site_uuid img_uuid
  uuids="$(echo "$url" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')"
  site_uuid="$(echo "$uuids" | sed -n '1p')"
  img_uuid="$(echo "$uuids" | sed -n '2p')"
  [[ -n "$site_uuid" && -n "$img_uuid" ]] || return 1

  # parse output width from dimension segment: x,y,srcW,srcH,outW,outH
  local outw
  outw="$(echo "$url" | grep -oE '/[0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+/' \
    | head -1 | tr -d '/' | cut -d, -f5)"
  [[ "${outw:-0}" -lt 2500 ]] || return 1

  local cache_file="${FORMAT_CACHE}/${site_uuid}.tsv"
  [[ -f "$cache_file" ]] || return 1

  local best_url
  best_url="$(awk -F'\t' -v id="$img_uuid" '$1 == id { print $2; exit }' "$cache_file")"
  [[ -n "$best_url" ]] || return 1

  echo "$best_url"
}

# -- Category D: Proprietary path CDNs ---------------------------------------

cdn_resolve_wsj() {
  local url="$1"
  [[ "$url" == *"images.wsj.net/im-"* ]] || return 1

  # WSJ uses Cloudinary; the server-timing header exposes the original width
  # (owidth).  Requesting ?width={owidth} returns the full-resolution image.
  local info owidth
  info="$(curl -sI -L "$url" 2>/dev/null)"
  owidth="$(echo "$info" | sed -n 's/.*owidth=\([0-9][0-9]*\).*/\1/p' | head -1)" || true

  if [[ -n "$owidth" && "$owidth" -gt 0 ]] 2>/dev/null; then
    append_param "$url" "width" "$owidth"
    return 0
  fi

  return 1
}

cdn_resolve_condenast() {
  local url="$1"
  [[ "$url" =~ media\..+\.com/photos/ ]] || return 1

  # /photos/{id}/{aspect}/{transform}/{filename}
  # Rewrite to /photos/{id}/master/pass/{filename}
  if [[ "$url" =~ ^(.*\/photos\/[^/]+\/)[^/]+\/[^/]+\/(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}master/pass/${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

cdn_resolve_google() {
  local url="$1"
  [[ "$url" =~ lh[0-9]*\.googleusercontent\.com ]] || return 1

  if [[ "$url" == *"="* ]]; then
    echo "${url%%=*}=s0"
  else
    echo "${url}=s0"
  fi
}

cdn_resolve_twitter() {
  local url="$1"
  [[ "$url" == *"pbs.twimg.com"* ]] || return 1

  if [[ "$url" == *"name="* ]]; then
    # replace name=anything with name=orig
    echo "$(echo "$url" | sed -E 's/name=[^&]*/name=orig/')"
  else
    append_param "$url" "name" "orig"
  fi
}

cdn_resolve_pinterest() {
  local url="$1"
  [[ "$url" == *"i.pinimg.com"* ]] || return 1

  # replace size segment like /236x/, /474x/, /736x/ with /originals/
  echo "$url" | sed -E 's|/[0-9]+x/|/originals/|'
}

cdn_resolve_ynap() {
  local url="$1"
  # YOOX NET-A-PORTER group: Mr Porter, Net-a-Porter
  # URL: cache.mrporter.com/variants/images/{id}/{variant}/w{W}_q{Q}.{ext}
  [[ "$url" =~ cache\.(mrporter|net-a-porter)\.com/variants/images/ ]] || return 1

  # Maximise width (2000 is well above most source images); quality is
  # whitelisted server-side — only q60 returns data, so keep it.
  echo "$url" | sed -E 's|/w[0-9]+_q[0-9]+\.|/w2000_q60.|'
}

# -- Category B: Path-segment CDNs -------------------------------------------

cdn_resolve_cloudinary() {
  local url="$1"
  [[ "$url" == *"res.cloudinary.com/"* ]] || return 1
  [[ "$url" == *"/image/upload/"* ]] || return 1

  local base="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  local before="${base%%/image/upload/*}"
  local after="${base#*/image/upload/}"

  # split remaining path into segments, skip transforms
  local result="" skipping=true seg
  local saved_IFS="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  set -- $after
  IFS="$saved_IFS"

  for seg in "$@"; do
    [[ -z "$seg" ]] && continue
    if $skipping && _is_cloudinary_transform "$seg"; then
      continue
    fi
    skipping=false
    result="${result}/${seg}"
  done

  result="${result#/}"
  [[ -n "$result" ]] || return 1
  echo "${before}/image/upload/${result}${query}"
}

cdn_resolve_uploadcare() {
  local url="$1"
  [[ "$url" == *"ucarecdn.com"* ]] || return 1
  [[ "$url" == *"/-/"* ]] || return 1

  echo "${url%%/-/*}"
}

cdn_resolve_storyblok() {
  local url="$1"
  [[ "$url" == *"storyblok.com"* ]] || return 1

  # remove /m/{options} at the end
  echo "$url" | sed -E 's|/m/[^ ]*$||'
}

cdn_resolve_tumblr() {
  local url="$1"
  [[ "$url" == *"media.tumblr.com"* ]] || return 1

  # remove size segment like /s540x810/ or /s{W}x{H}_{suffix}/
  echo "$url" | sed -E 's|/s[0-9]+x[0-9]+[^/]*/|/|'
}

cdn_resolve_cargo() {
  local url="$1"
  [[ "$url" == *"freight.cargo.site"* || "$url" == *"cortex.persona.co"* ]] || return 1
  [[ "$url" == */i/* ]] || return 1

  # Cargo CMS image CDN.  Display URLs contain resize/quality path segments:
  #   /w/{width}/q/{quality}/t/{type}/i/{hash}/{filename}
  # Strip /w/, /h/, /q/, /t/ prefixes and request /t/original/i/... for the
  # full-resolution original.
  local scheme_host tail
  # extract scheme+host (everything up to the first path slash)
  scheme_host="${url%%/w/*}"
  [[ "$scheme_host" == "$url" ]] && scheme_host="${url%%/h/*}"
  [[ "$scheme_host" == "$url" ]] && scheme_host="${url%%/q/*}"
  [[ "$scheme_host" == "$url" ]] && scheme_host="${url%%/t/*}"
  [[ "$scheme_host" == "$url" ]] && scheme_host="${url%%/i/*}"

  # extract everything from /i/ onward
  tail="/i/${url##*/i/}"

  local result="${scheme_host}/t/original${tail}"
  [[ "$result" != "$url" ]] || return 1
  echo "$result"
}

# -- Category C: Filename-suffix CDNs ----------------------------------------

cdn_resolve_imgur() {
  local url="$1"
  [[ "$url" == *"i.imgur.com"* ]] || return 1

  # remove single-char size suffix before extension: abc123s.jpg -> abc123.jpg
  echo "$url" | sed -E 's|/([a-zA-Z0-9]+)[sbtmlh]\.([a-z]+)$|/\1.\2|'
}

# Flickr: try larger size suffixes (requires HEAD checks).
cdn_resolve_flickr() {
  local url="$1"
  [[ "$url" == *"staticflickr.com"* ]] || return 1

  local base_url="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  # extract suffix pattern: _X before extension
  if [[ "$base_url" =~ ^(.+)_[a-z]\.([a-z]+)$ ]]; then
    local stem="${BASH_REMATCH[1]}"
    local ext="${BASH_REMATCH[2]}"

    # try sizes: _o (original), _k (2048), _b (1024)
    for suffix in o k b; do
      local try_url="${stem}_${suffix}.${ext}${query}"
      local status
      status="$(http_status "$try_url")"
      if [[ "$status" == 2* ]]; then
        echo "$try_url"
        return 0
      fi
    done
  fi

  return 1
}

cdn_resolve_cargocollective() {
  local url="$1"
  [[ "$url" == *"cargocollective.com"* ]] || return 1

  # payload*.cargocollective.com: strip size suffix from filename
  # e.g. image_1000.jpg -> image.jpg, image_1340_c.jpg -> image.jpg
  local result
  result="$(echo "$url" | sed -E 's/_[0-9]{3,4}(_c)?(\.[a-z]+)$/\2/')"
  [[ "$result" != "$url" ]] || return 1
  echo "$result"
}

cdn_resolve_shopify_legacy() {
  local url="$1"
  [[ "$url" == *"cdn.shopify.com"* ]] || return 1

  local result
  # remove size suffix: _100x100, _100x100_crop_center, _grande, _large, etc.
  result="$(echo "$url" | sed -E \
    's/_[0-9]+x[0-9]+(_crop_[a-z]+)?(\.[a-z]+)/\2/;
     s/_(pico|icon|thumb|small|compact|medium|large|grande|original|master)(\.[a-z]+)/\2/')"
  [[ "$result" != "$url" ]] || return 1
  echo "$result"
}

# -- Category A: Query-param CDNs (strip params for original) ----------------

cdn_resolve_imgix() {
  local url="$1"
  [[ "$url" == *".imgix.net"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_sanity() {
  local url="$1"
  [[ "$url" == *"cdn.sanity.io"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_contentful() {
  local url="$1"
  [[ "$url" == *"images.ctfassets.net"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_shopify() {
  local url="$1"
  [[ "$url" == *"cdn.shopify.com"* ]] || return 1
  [[ "$url" == *"?"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_akamai() {
  local url="$1"
  [[ "$url" == *"im="* ]] || [[ "$url" == *"imwidth="* ]] || return 1
  strip_url_params "$url" im imwidth imheight imbypass imformat imquality impolicy
}

cdn_resolve_fastly() {
  local url="$1"
  # require at least 2 Fastly IO-style params to reduce false positives
  local count=0
  [[ "$url" == *"width="* ]]   && (( count++ )) || true
  [[ "$url" == *"height="* ]]  && (( count++ )) || true
  [[ "$url" == *"format="* ]]  && (( count++ )) || true
  [[ "$url" == *"quality="* ]] && (( count++ )) || true
  [[ "$url" == *"fit="* ]]     && (( count++ )) || true
  (( count >= 2 )) || return 1
  strip_url_params "$url" width height format quality fit crop
}

cdn_resolve_bunny() {
  local url="$1"
  [[ "$url" == *".b-cdn.net"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_sirv() {
  local url="$1"
  [[ "$url" == *".sirv.com"* ]] || return 1
  echo "${url%%\?*}"
}

cdn_resolve_hypbst() {
  local url="$1"
  [[ "$url" == *"image-cdn.hypb.st"* ]] || return 1
  # Hypebeast CDN (CloudFront + Lambda): supports w, q, format params.
  # Request native resolution (w=9999 caps at original, no upscaling)
  # and max quality (q=100) to get the best JPEG decode before format probing.
  local base="${url%%\?*}"
  echo "${base}?q=100&w=9999"
}

cdn_resolve_arc_resizer() {
  local url="$1"
  # Arc Publishing / Arc XP resizer (used by WaPo, Business of Fashion, many news orgs).
  # URL pattern: /resizer/v2/HASH.ext?auth=TOKEN[&width=X&quality=Y]
  # The auth token remains valid when adding extra params.
  # imbypass=true bypasses the resizer entirely and returns the original file
  # with full EXIF metadata and no re-encoding.
  [[ "$url" == */resizer/* ]] || return 1
  [[ "$url" == *"auth="* ]] || return 1
  append_param "$url" "imbypass" "true"
}

# -- Generic fallback ---------------------------------------------------------

cdn_resolve_generic() {
  local url="$1"
  [[ "$GENERIC_STRIP" == "true" ]] || return 1
  [[ "$url" == *"?"* ]] || return 1

  local base="${url%%\?*}"
  # only strip if URL has an image file extension
  echo "$base" | grep -qiE '\.(jpe?g|png|gif|webp|tiff?|bmp)$' || return 1
  echo "$base"
}

# -- Format.com site discovery (populates cache for cdn_resolve_format) --------

_FORMAT_DISCOVERED_CACHE=""

format_discover() {
  local site_url="$1"
  mkdir -p "$FORMAT_CACHE"

  local base ua
  base="$(echo "$site_url" | sed -E 's|(https?://[^/]+).*|\1|')"
  ua='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

  echo "Discovering Format.com portfolio: $base"

  # collect internal page paths from homepage nav
  local pages=()
  while IFS= read -r href; do
    case "$href" in
      /static/*|*.css*|*.js*|\#*|*\#*) continue ;;
      /*) pages+=("${base}${href}") ;;
    esac
  done < <(curl -sL "$base" -H "User-Agent: $ua" \
    | grep -oE 'href="[^"]*"' | sed 's/href="//;s/"$//' | sort -u)

  # include specific page if it differs from base
  if [[ "$site_url" != "$base" && "$site_url" != "${base}/" ]]; then
    pages+=("$site_url")
  fi

  local tmpfile
  tmpfile="$(mktemp)"

  local page
  for page in "${pages[@]}"; do
    echo "  crawling $page"
    local raw_urls
    raw_urls="$(curl -sL "$page" -H "User-Agent: $ua" \
      | grep -oE 'https://format\.creatorcdn\.com/[^"'"'"' >]+/[0-9]+,[0-9]+,[0-9]+,[0-9]+,2500,[0-9]+/[^"'"'"' >]+' \
      | sort -u)" || true
    [[ -z "$raw_urls" ]] && continue

    while IFS= read -r img_url; do
      local i_uuid
      i_uuid="$(echo "$img_url" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sed -n '2p')"
      [[ -n "$i_uuid" ]] || continue
      printf '%s\t%s\n' "$i_uuid" "$img_url"
    done <<< "$raw_urls" >> "$tmpfile"
  done

  if [[ -s "$tmpfile" ]]; then
    local site_uuid count
    site_uuid="$(head -1 "$tmpfile" | cut -f2 \
      | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
    sort -u -t$'\t' -k1,1 "$tmpfile" > "${FORMAT_CACHE}/${site_uuid}.tsv"
    count="$(wc -l < "${FORMAT_CACHE}/${site_uuid}.tsv" | tr -d ' ')"
    echo "  cached $count images → ${FORMAT_CACHE}/${site_uuid}.tsv"
    _FORMAT_DISCOVERED_CACHE="${FORMAT_CACHE}/${site_uuid}.tsv"
  else
    echo "  no Format.com images found on site"
  fi

  rm -f "$tmpfile"
}

# -- dispatcher ---------------------------------------------------------------

cdn_resolve() {
  local url="$1"
  $NO_CDN && { echo "$url"; return; }

  local resolved=""

  # Category E: proxy CDNs (extract original URL)
  resolved="$(cdn_resolve_nextjs "$url" 2>/dev/null)"             || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_netlify "$url" 2>/dev/null)"            || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_wp_photon "$url" 2>/dev/null)"          || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_wp_uploads "$url" 2>/dev/null)"        || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_cloudflare_images "$url" 2>/dev/null)"  || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_thumbor "$url" 2>/dev/null)"            || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_format "$url" 2>/dev/null)"             || true

  # Category D: proprietary path CDNs
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_wsj "$url" 2>/dev/null)"        || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_condenast "$url" 2>/dev/null)"  || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_google "$url" 2>/dev/null)"     || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_twitter "$url" 2>/dev/null)"    || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_pinterest "$url" 2>/dev/null)"  || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_ynap "$url" 2>/dev/null)"      || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_arc_resizer "$url" 2>/dev/null)" || true

  # Category B: path-segment CDNs
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_cloudinary "$url" 2>/dev/null)"   || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_uploadcare "$url" 2>/dev/null)"   || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_storyblok "$url" 2>/dev/null)"    || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_tumblr "$url" 2>/dev/null)"       || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_cargo "$url" 2>/dev/null)"        || true

  # Category C: filename-suffix CDNs
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_imgur "$url" 2>/dev/null)"            || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_flickr "$url" 2>/dev/null)"           || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_shopify_legacy "$url" 2>/dev/null)"   || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_cargocollective "$url" 2>/dev/null)" || true

  # Category A: query-param CDNs
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_imgix "$url" 2>/dev/null)"      || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_sanity "$url" 2>/dev/null)"     || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_contentful "$url" 2>/dev/null)" || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_shopify "$url" 2>/dev/null)"    || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_akamai "$url" 2>/dev/null)"     || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_fastly "$url" 2>/dev/null)"     || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_bunny "$url" 2>/dev/null)"      || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_sirv "$url" 2>/dev/null)"       || true
  [[ -n "$resolved" ]] || resolved="$(cdn_resolve_hypbst "$url" 2>/dev/null)"    || true

  # Generic fallback: strip query params if it yields a larger file
  if [[ -z "$resolved" ]]; then
    local generic
    generic="$(cdn_resolve_generic "$url" 2>/dev/null)" || true
    if [[ -n "$generic" && "$generic" != "$url" ]]; then
      local orig_info orig_cl gen_info gen_cl
      orig_info="$(head_info "$url")"
      orig_cl="$(sed -n '2p' <<< "$orig_info")"
      gen_info="$(head_info "$generic")"
      gen_cl="$(sed -n '2p' <<< "$gen_info")"
      if (( ${gen_cl:-0} > ${orig_cl:-0} )); then
        resolved="$generic"
      fi
    fi
  fi

  # Validate resolved URL with HEAD
  if [[ -n "$resolved" && "$resolved" != "$url" ]]; then
    local status
    status="$(http_status "$resolved")"
    if [[ "$status" == 2* ]]; then
      echo "$resolved"
      return 0
    fi
  fi

  echo "$url"
}

# ── candidate collector ──────────────────────────────────────────────────────
# Each candidate is stored as: "priority:size:fmt:download_url"
# We collect all and pick the best at the end.

CANDIDATES=()

add_candidate() {
  local fmt="$1" size="$2" dl_url="$3" source="${4:-B}"
  local pri
  pri="$(fmt_priority "$fmt")"
  [[ "$pri" -eq 99 ]] && return  # unknown format, skip
  # reject tiny responses — likely placeholder or error images
  if [[ "${size:-0}" -gt 0 ]] && (( size < 1024 )); then
    echo "   skip ${fmt} candidate (${size}B — likely placeholder)" >&2
    return
  fi
  CANDIDATES+=("${pri}:${size}:${fmt}:${source}:${dl_url}")
}

# Select best candidate: lowest priority number, then largest size.
# Size-dominance override: if any candidate is SIZE_DOMINANCE_RATIO times
# larger than the format-priority winner, the larger one wins.
select_best() {
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    return 1
  fi

  # first pass: format-priority winner
  local best="" best_pri=99 best_size=0
  for c in "${CANDIDATES[@]}"; do
    IFS=: read -r pri size fmt source url <<< "$c"
    size="${size:-0}"
    if (( pri < best_pri )) || { (( pri == best_pri )) && (( size > best_size )); }; then
      best="$c"
      best_pri="$pri"
      best_size="$size"
    fi
  done

  # second pass: size-dominance check
  if (( SIZE_DOMINANCE_RATIO > 0 && best_size > 0 )); then
    local largest="" largest_size=0
    for c in "${CANDIDATES[@]}"; do
      IFS=: read -r pri size fmt source url <<< "$c"
      size="${size:-0}"
      if (( size > largest_size )); then
        largest="$c"
        largest_size="$size"
      fi
    done

    if (( largest_size >= best_size * SIZE_DOMINANCE_RATIO )); then
      # don't let palette-indexed PNGs or detected transcodes override
      # via size — their inflated file size doesn't reflect actual quality
      IFS=: read -r _l_pri _l_size l_fmt _l_source _l_url <<< "$largest"
      if [[ "$l_fmt" != "png-indexed" && "$l_fmt" != *-transcode ]]; then
        best="$largest"
      fi
    fi
  fi

  echo "$best"
}

# ── probing strategies ───────────────────────────────────────────────────────

# Strategy 0: baseline — just check what the original URL gives us.
baseline_probe() {
  local url="$1" source="${2:-B}"
  local info ct cl fmt
  info="$(head_info "$url")"
  ct="$(sed -n '1p' <<< "$info")"
  cl="$(sed -n '2p' <<< "$info")"
  fmt="$(ct_to_fmt "$ct")"
  add_candidate "$fmt" "$cl" "$url" "$source"

  # expose baseline format so other strategies can short-circuit
  BASELINE_FMT="$fmt"
  BASELINE_CT="$ct"
  BASELINE_SIZE="${cl:-0}"
}

# Strategy 1: HTTP Accept header negotiation.
accept_probe() {
  local url="$1"
  local accept_types=( "image/tiff" "image/png" "image/jpeg" "image/webp" )

  for accept in "${accept_types[@]}"; do
    local info ct cl fmt
    info="$(head_info "$url" -H "Accept: ${accept}")"
    ct="$(sed -n '1p' <<< "$info")"
    cl="$(sed -n '2p' <<< "$info")"
    fmt="$(ct_to_fmt "$ct")"

    if [[ "$fmt" != "unknown" ]]; then
      add_candidate "$fmt" "$cl" "$url" "A"
    fi
  done
}

# Strategy 2: CDN query-parameter probing.
param_probe() {
  local url="$1"

  for param in "${PARAM_PATTERNS[@]}"; do
    local found_working=false

    for fm in "${PROBE_FMTS[@]}"; do
      local probe_url info ct cl fmt
      probe_url="$(append_param "$url" "$param" "$fm")"
      info="$(head_info "$probe_url")"
      ct="$(sed -n '1p' <<< "$info")"
      cl="$(sed -n '2p' <<< "$info")"
      fmt="$(ct_to_fmt "$ct")"

      if [[ "$fmt" != "unknown" ]]; then
        [[ "$ct" != "$BASELINE_CT" ]] && found_working=true
        add_candidate "$fmt" "$cl" "$probe_url" "P"
      fi

      { [[ "$PROBE_DELAY" != "0" ]] && sleep "$PROBE_DELAY"; } || true
    done

    # if this param pattern produced different formats, no need to try others
    $found_working && return 0
  done
  return 0
}

# Strategy 3: URL path extension swapping.
path_probe() {
  local url="$1"
  local base_url="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  # only attempt if URL has a recognizable image extension
  local has_ext=false
  for ext in tif tiff png jpg jpeg webp; do
    if echo "$base_url" | grep -qi "\.${ext}$"; then
      has_ext=true
      break
    fi
  done
  $has_ext || return 0

  # strip current extension
  local stem="${base_url%.*}"

  for ext in "${PATH_EXTS[@]}"; do
    local probe_url="${stem}.${ext}${query}"
    local info ct cl fmt http_code

    # use -o /dev/null -w to check HTTP status too
    http_code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 "$probe_url" 2>/dev/null)"
    [[ "$http_code" == 2* ]] || continue

    info="$(head_info "$probe_url")"
    ct="$(sed -n '1p' <<< "$info")"
    cl="$(sed -n '2p' <<< "$info")"
    fmt="$(ct_to_fmt "$ct")"

    if [[ "$fmt" != "unknown" ]]; then
      add_candidate "$fmt" "$cl" "$probe_url" "X"
    fi

    { [[ "$PROBE_DELAY" != "0" ]] && sleep "$PROBE_DELAY"; } || true
  done
}

# Strategy 4: video/audio bitrate probing.
# Detects bitrate patterns in URLs and probes higher-quality variants.
bitrate_probe() {
  local url="$1"
  local base_url="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  # detect bitrate pattern in filename: common forms like -1200000.mp4, _1200000.mp4
  local filename="${base_url##*/}"
  local dirpath="${base_url%/*}"
  local current_br=""
  local prefix="" suffix=""

  # pattern: {prefix}{sep}{bitrate}.{ext}  where sep is - or _
  if [[ "$filename" =~ ^(.*[-_])([0-9]{4,})\.([a-zA-Z0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    current_br="${BASH_REMATCH[2]}"
    suffix=".${BASH_REMATCH[3]}"
  # pattern: bitrate in directory path segment e.g. /1200000/filename.ext
  elif [[ "$base_url" =~ ^(.*/)([0-9]{4,})(/.*)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    current_br="${BASH_REMATCH[2]}"
    suffix="${BASH_REMATCH[3]}"
    dirpath=""  # prefix already contains full path
  else
    return 0
  fi

  [[ -n "$current_br" ]] || return 0

  # build list of bitrates to try, higher than current
  local try_bitrates=()
  local br_int=$((10#$current_br))

  # standard video bitrates (bps): 1.5M, 2M, 2.5M, 3M, 4M, 5M, 6M, 8M, 10M, 15M, 20M, 25M, 50M
  for candidate in 1500000 2000000 2500000 3000000 4000000 5000000 6000000 8000000 10000000 15000000 20000000 25000000 50000000; do
    (( candidate > br_int )) && try_bitrates+=("$candidate")
  done

  # also try kbps-scale if current bitrate looks like kbps (< 100000)
  if (( br_int < 100000 )); then
    for candidate in 1500 2000 2500 3000 4000 5000 6000 8000 10000 15000 20000 25000 50000; do
      (( candidate > br_int )) && try_bitrates+=("$candidate")
    done
  fi

  [[ ${#try_bitrates[@]} -gt 0 ]] || return 0

  local found_any=false
  for br in "${try_bitrates[@]}"; do
    local probe_url
    if [[ -n "$dirpath" ]]; then
      probe_url="${dirpath}/${prefix}${br}${suffix}${query}"
    else
      probe_url="${prefix}${br}${suffix}${query}"
    fi

    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 "$probe_url" 2>/dev/null)"
    [[ "$http_code" == 2* ]] || continue

    local info ct cl fmt
    info="$(head_info "$probe_url")"
    ct="$(sed -n '1p' <<< "$info")"
    cl="$(sed -n '2p' <<< "$info")"
    fmt="$(ct_to_fmt "$ct")"

    if [[ "$fmt" != "unknown" ]]; then
      add_candidate "$fmt" "$cl" "$probe_url" "R"
      found_any=true
    fi

    { [[ "$PROBE_DELAY" != "0" ]] && sleep "$PROBE_DELAY"; } || true
  done

  $found_any && return 0
  return 0
}

# ── Mux HLS handler ─────────────────────────────────────────────────────────
# Mux (stream.mux.com) serves capped progressive MP4s to browsers but exposes
# the full rendition ladder (up to 4K) via HLS.  When yt-dlp is available we
# fetch the best rendition; otherwise we fall back to the capped progressive.
#
# Returns: 0 = handled OK, 1 = not a Mux URL, 2 = download failed.

handle_mux() {
  local url="$1" stem="$2"

  # extract playback ID from stream.mux.com/{PID}[/...] or {PID}.m3u8
  [[ "$url" =~ stream\.mux\.com/([a-zA-Z0-9]+) ]] || return 1
  local pid="${BASH_REMATCH[1]}"

  local hls_url="https://stream.mux.com/${pid}.m3u8"

  # fix generic stems — Mux path segments are not useful filenames
  case "$stem" in
    capped-*|high|medium|low|"$pid") stem="mux_${pid}" ;;
  esac

  local out="${OUTDIR}/${stem}.mp4"

  # skip if already downloaded (>1 MB = not a partial/corrupt fragment)
  if [[ -f "$out" ]]; then
    local local_size
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if (( local_size > 1048576 )); then
      echo "   SKIP (already exists, $(( local_size / 1024 / 1024 )) MB): $out"
      return 0
    fi
  fi

  if has_ytdlp; then
    echo "   Mux HLS detected — fetching manifest..."

    # display available renditions
    local manifest_info
    manifest_info="$(yt-dlp --list-formats "$hls_url" 2>/dev/null)" || true
    if [[ -n "$manifest_info" ]]; then
      local best_res best_tbr
      best_res="$(echo "$manifest_info" | grep -oE '[0-9]+x[0-9]+' | tail -1)" || true
      best_tbr="$(echo "$manifest_info" | grep -E '[0-9]+x[0-9]+' | tail -1 | grep -oE '[0-9]+k' | head -1)" || true
      echo "   renditions:"
      echo "$manifest_info" | grep -E '[0-9]+x[0-9]+' | while IFS= read -r line; do
        echo "     $line"
      done
      [[ -n "$best_res" ]] && echo "   best → ${best_res} @ ${best_tbr:-?}bps"
    fi

    echo "   downloading via yt-dlp → $out"
    if yt-dlp \
        -f "bestvideo+bestaudio/best" \
        --merge-output-format mp4 \
        -o "$out" \
        --no-overwrites \
        "$hls_url" 2>&1 | sed 's/^/   /'; then
      return 0
    else
      echo "   !! yt-dlp HLS failed — trying progressive fallback..." >&2
    fi
  else
    echo "   Mux detected — yt-dlp not found, using capped progressive MP4"
    echo "   (install yt-dlp for full-quality HLS downloads)"
  fi

  # fallback: capped progressive MP4 via aria2c
  local prog_url="https://stream.mux.com/${pid}/capped-1080p.mp4"
  echo "   downloading progressive → $out"
  if aria2c -c -x 16 -s 16 -k 1M -o "$(basename "$out")" -d "$OUTDIR" "$prog_url" --quiet; then
    return 0
  fi
  return 2
}

# ── Vimeo handler ───────────────────────────────────────────────────────────
# When --vimeo is active: full pipeline (JWT API → player config → yt-dlp).
# Otherwise: lightweight yt-dlp-only path (no cookies/python3 needed).
#
# Returns: 0 = handled OK, 1 = not a Vimeo URL, 2 = download failed.

handle_vimeo() {
  local url="$1" stem="$2" referer="${3:-}"
  local vimeo_id=""

  # extract Vimeo ID from various URL forms
  if [[ "$url" =~ player\.vimeo\.com/video/([0-9]+) ]]; then
    vimeo_id="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ vimeo\.com/([0-9]+) ]]; then
    vimeo_id="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^vimeo:([0-9]+)$ ]]; then
    vimeo_id="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  # ── Full Vimeo pipeline (--vimeo mode) ────────────────────────────────────
  if $VIMEO_MODE; then
    local full_url="$url"
    [[ "$url" =~ ^vimeo: ]] && full_url="https://vimeo.com/${vimeo_id}"
    # If we have an external referer (from page scraping), treat as embed page
    if [[ -n "$referer" && "$referer" != "$url" && "$referer" != *"vimeo.com"* ]]; then
      # Try API first, then player config with referer
      printf "${CYAN}[info]${RESET}  Processing video ${BOLD}%s${RESET} (embed, referer: %s)\n" "$vimeo_id" "$referer"
      if ! vimeo_process_api "$vimeo_id" 2>/dev/null; then
        vwarn "API unavailable for $vimeo_id — trying player config path"
        vimeo_process_player "$vimeo_id" "$referer"
      fi
    else
      vimeo_process_url "$full_url"
    fi
    return $?
  fi

  # ── Lightweight yt-dlp-only path (no --vimeo) ────────────────────────────
  [[ -z "$referer" ]] && referer="$url"

  # fix generic stems
  case "$stem" in
    video|"$vimeo_id") stem="vimeo_${vimeo_id}" ;;
  esac

  local out="${OUTDIR}/${stem}.mp4"

  # skip if already downloaded (>1 MB)
  if [[ -f "$out" ]]; then
    local local_size
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if (( local_size > 1048576 )); then
      echo "   SKIP (already exists, $(( local_size / 1024 / 1024 )) MB): $out"
      return 0
    fi
  fi

  if ! has_ytdlp; then
    echo "   Vimeo detected but yt-dlp not found — cannot download" >&2
    return 2
  fi

  echo "   Vimeo ${vimeo_id} — fetching renditions..."

  local dl_url ref_args=() manifest_info=""

  if [[ -n "$referer" && "$referer" != "$url" && "$referer" != *"vimeo.com"* ]]; then
    dl_url="https://player.vimeo.com/video/${vimeo_id}"
    ref_args=(--referer "$referer")
    manifest_info="$(yt-dlp --list-formats "${ref_args[@]}" "$dl_url" 2>/dev/null)" || true
  fi

  if [[ -z "$manifest_info" ]]; then
    dl_url="https://vimeo.com/${vimeo_id}"
    ref_args=()
    manifest_info="$(yt-dlp --list-formats "$dl_url" 2>/dev/null)" || true
  fi

  if [[ -z "$manifest_info" ]] || ! echo "$manifest_info" | grep -qE '[0-9]+x[0-9]+'; then
    echo "   !! embed-only video — needs the URL of the page that embeds it" >&2
    echo "   usage: bash app.sh 'https://example.com/page-with-video'" >&2
    echo "   (the page must server-render the Vimeo embed, not load it via JS)" >&2
    return 2
  fi

  local best_res best_tbr
  best_res="$(echo "$manifest_info" | grep -oE '[0-9]+x[0-9]+' | tail -1)" || true
  best_tbr="$(echo "$manifest_info" | grep -E '[0-9]+x[0-9]+' | tail -1 | grep -oE '[0-9]+k' | head -1)" || true
  echo "   renditions:"
  echo "$manifest_info" | grep -E '[0-9]+x[0-9]+' | sort -t'|' -k2 -n | uniq | while IFS= read -r line; do
    echo "     $line"
  done
  [[ -n "$best_res" ]] && echo "   best → ${best_res} @ ${best_tbr:-?}bps"

  echo "   downloading via yt-dlp → $out"
  if yt-dlp \
      -f "bestvideo+bestaudio/best" \
      --merge-output-format mp4 \
      ${ref_args[@]+"${ref_args[@]}"} \
      -o "$out" \
      --no-overwrites \
      "$dl_url" 2>&1 | sed 's/^/   /'; then
    return 0
  fi
  return 2
}

# Extract Mux playback IDs from a webpage.
# Prefers IDs found on image.mux.com (real players with thumbnails) over
# IDs only on stream.mux.com (often og:video social-share previews).
# Echoes one playback ID per line; returns 1 if none found.
extract_mux_from_page() {
  local url="$1"
  local html
  html="$(curl -sL --max-time 15 "$url" 2>/dev/null)" || return 1
  [[ -n "$html" ]] || return 1

  # collect IDs from image.mux.com (definite player videos — they have thumbnails)
  local image_ids
  image_ids="$(echo "$html" | grep -oE 'image\.mux\.com/[a-zA-Z0-9]+' \
    | sed 's|image\.mux\.com/||' | sort -u)"

  if [[ -n "$image_ids" ]]; then
    echo "$image_ids"
    return 0
  fi

  # fallback: all IDs from stream.mux.com (may include og:video previews)
  local stream_ids
  stream_ids="$(echo "$html" | grep -oE 'stream\.mux\.com/[a-zA-Z0-9]+' \
    | sed 's|stream\.mux\.com/||' | sort -u)"

  if [[ -n "$stream_ids" ]]; then
    echo "$stream_ids"
    return 0
  fi

  return 1
}

# Extract Vimeo video IDs from a webpage.
# Uses the 8-strategy vimeo_scrape_embed_ids scraper; strips |referer suffix
# so callers receive bare IDs (one per line).
extract_vimeo_from_page() {
  local url="$1"
  local embed_data
  embed_data=$(vimeo_scrape_embed_ids "$url") || return 1
  echo "$embed_data" | cut -d'|' -f1
}

# ── input handling ───────────────────────────────────────────────────────────

usage() {
  cat <<'USAGE'
Usage: app.sh [-o OUTDIR] [--no-cdn] [--filename NAME] [FILE | URL ...]
       app.sh -c <cookies.txt> --vimeo [--force-download] [FILE | URL | ID ...]

  FILE          Text file with one URL per line (# comments, blank lines ok)
  URL ...       One or more URLs as arguments
  ID  ...       Bare Vimeo IDs (6+ digits, requires --vimeo)
  stdin         Pipe URLs via stdin
  -o OUTDIR     Output directory (default: ./downloads)
  --no-cdn      Skip CDN resolution (no URL rewriting)
  --trust-cdn   Disable transcode detection (download largest file regardless)
  --filename NAME  Custom output filename (without extension; extension is
                   added automatically based on the best format found)
  --format-discover URL  Crawl a Format.com portfolio site, cache all
                         image URLs at max resolution (2500px), then
                         download them. Cache persists for future runs.

Vimeo options (requires python3):
  --vimeo              Full Vimeo pipeline: JWT API source files → player
                       config progressive MP4 → yt-dlp HLS/DASH fallback
  -c, --cookies FILE   Netscape-format cookies file (required with --vimeo)
  --force-download     Download regardless of file size (default: skip < 150 MB)

Examples:
  app.sh -c cookies.txt --vimeo 385365963
  app.sh -c cookies.txt --vimeo https://vimeo.com/252387977
  app.sh -c cookies.txt --vimeo https://example.com/page-with-embed
  app.sh -c cookies.txt --vimeo --force-download urls.txt
USAGE
  exit 1
}

read_urls() {
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    echo "$line"
  done
}

collect_urls() {
  local urls=()

  if [[ ${#POSITIONAL[@]} -eq 0 ]] && [[ ! -t 0 ]]; then
    # stdin
    while IFS= read -r u; do urls+=("$u"); done < <(read_urls)
  elif [[ ${#POSITIONAL[@]} -eq 1 ]] && [[ -f "${POSITIONAL[0]}" ]]; then
    # single file argument
    while IFS= read -r u; do urls+=("$u"); done < <(read_urls < "${POSITIONAL[0]}")
  elif [[ ${#POSITIONAL[@]} -ge 1 ]]; then
    # URLs as arguments (or first arg is a file)
    for arg in "${POSITIONAL[@]}"; do
      if [[ -f "$arg" ]]; then
        while IFS= read -r u; do urls+=("$u"); done < <(read_urls < "$arg")
      else
        urls+=("$arg")
      fi
    done
  else
    usage
  fi

  [[ ${#urls[@]} -gt 0 ]] && printf '%s\n' "${urls[@]}"
}

# ── main ─────────────────────────────────────────────────────────────────────

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTDIR="$2"; shift 2 ;;
    -c|--cookies)      COOKIES="$2"; shift 2 ;;
    --vimeo)           VIMEO_MODE=true; shift ;;
    --force-download)  FORCE_DOWNLOAD=true; shift ;;
    --no-cdn)    NO_CDN=true; shift ;;
    --trust-cdn) TRUST_CDN=true; shift ;;
    --referer)   VIMEO_REFERER="$2"; shift 2 ;;
    --filename)  CUSTOM_FILENAME="$2"; shift 2 ;;
    --format-discover) FORMAT_DISCOVER="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *)           POSITIONAL+=("$1"); shift ;;
  esac
done

# --vimeo validation
if $VIMEO_MODE; then
  if ! has_python3; then
    echo "ERROR: --vimeo requires python3 (for JSON parsing, JWT decoding)" >&2
    exit 1
  fi
  if [[ -z "$COOKIES" ]]; then
    echo "ERROR: --vimeo requires cookies (-c <cookies.txt>)" >&2
    exit 1
  fi
  if [[ ! -f "$COOKIES" ]]; then
    echo "ERROR: Cookies file not found: $COOKIES" >&2
    exit 1
  fi
fi

# detect curl_cffi for Cloudflare TLS fingerprint bypass
if has_python3 && has_curl_cffi; then
  HAVE_CURL_CFFI=true
fi

mkdir -p "$OUTDIR"

# Format.com discovery — crawl site and cache all 2500w signed URLs
if [[ -n "$FORMAT_DISCOVER" ]]; then
  format_discover "$FORMAT_DISCOVER"
  # discovery-only when no other URLs provided
  if [[ ${#POSITIONAL[@]} -eq 0 ]] && [[ -t 0 ]]; then
    echo ""
    echo "Discovery complete. Cache: ${_FORMAT_DISCOVERED_CACHE:-none}"
    echo "Format.com CDN URLs will now auto-resolve to max resolution."
    exit 0
  fi
fi

# counters for summary
TOTAL=0; OK=0; FAIL=0

while IFS= read -r url; do
  # Expand bare Vimeo IDs when --vimeo is active
  if $VIMEO_MODE && [[ "$url" =~ ^[0-9]{6,}$ ]]; then
    url="https://vimeo.com/${url}"
  fi

  (( TOTAL++ )) || true
  CANDIDATES=()
  BASELINE_FMT="unknown"
  BASELINE_CT="unknown"
  BASELINE_SIZE=0
  BASELINE_DIMS=""

  stem="$(basename_from_url "$url")"
  [[ -n "$CUSTOM_FILENAME" ]] && stem="$CUSTOM_FILENAME"
  echo ""
  echo "── [$TOTAL] $url"

  # ── Video platform early intercepts — bypass normal probe pipeline ───────

  # Direct Mux stream URL
  if [[ "$url" == *"stream.mux.com/"* ]]; then
    handle_mux "$url" "$stem"
    mux_rc=$?
    if [[ $mux_rc -eq 0 ]]; then (( OK++ )) || true; continue
    elif [[ $mux_rc -eq 2 ]]; then echo "   !! download failed" >&2; (( FAIL++ )) || true; continue; fi

  # Direct Vimeo URL
  elif [[ "$url" == *"vimeo.com/"* ]]; then
    handle_vimeo "$url" "$stem" "$VIMEO_REFERER"
    vim_rc=$?
    if [[ $vim_rc -eq 0 ]]; then (( OK++ )) || true; continue
    elif [[ $vim_rc -eq 2 ]]; then echo "   !! download failed" >&2; (( FAIL++ )) || true; continue; fi

  # Page extraction: if URL looks like a webpage, try extracting embedded videos.
  elif ! echo "$url" | grep -qiE '\.(jpe?g|png|gif|webp|tiff?|mp[34]|webm|mov|flac|wav|aac|ogg|m3u8)(\?|$)' \
    && ! echo "$url" | grep -qE '(images?\.(mux|wsj|unsplash)|i[0-9]*\.(wp|imgur)|pbs\.twimg|staticflickr|res\.cloudinary|cdn-cgi/image|wp-content/uploads|vimeocdn)'; then

    page_handled=false

    # Try Mux extraction
    echo "   checking page for embedded videos..."
    mux_pids="$(extract_mux_from_page "$url")" || true
    if [[ -n "$mux_pids" ]]; then
      pid_count="$(echo "$mux_pids" | wc -l | tr -d ' ')"
      echo "   found ${pid_count} Mux video(s)"
      vid_ok=0; vid_fail=0; vid_idx=0
      while IFS= read -r pid; do
        (( vid_idx++ )) || true
        local_stem="$stem"
        (( pid_count > 1 )) && local_stem="${stem}_${vid_idx}"
        mux_url="https://stream.mux.com/${pid}/capped-1080p.mp4"
        (( pid_count > 1 )) && { echo ""; echo "   ── video ${vid_idx}/${pid_count}"; }
        handle_mux "$mux_url" "$local_stem"
        rc=$?
        if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
        elif [[ $rc -eq 2 ]]; then echo "   !! download failed" >&2; (( vid_fail++ )) || true; fi
      done <<< "$mux_pids"
      (( OK += vid_ok )) || true
      (( FAIL += vid_fail )) || true
      (( TOTAL += vid_ok + vid_fail - 1 )) || true
      page_handled=true
    fi

    # Try Vimeo extraction (from the same or fresh page fetch)
    if ! $page_handled; then
      vimeo_ids="$(extract_vimeo_from_page "$url")" || true
      if [[ -n "$vimeo_ids" ]]; then
        vid_count="$(echo "$vimeo_ids" | wc -l | tr -d ' ')"
        echo "   found ${vid_count} Vimeo video(s)"
        vid_ok=0; vid_fail=0; vid_idx=0
        while IFS= read -r vid; do
          (( vid_idx++ )) || true
          local_stem="$stem"
          (( vid_count > 1 )) && local_stem="${stem}_${vid_idx}"
          (( vid_count > 1 )) && { echo ""; echo "   ── video ${vid_idx}/${vid_count}"; }
          handle_vimeo "vimeo:${vid}" "$local_stem" "$url"
          rc=$?
          if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
          elif [[ $rc -eq 2 ]]; then echo "   !! download failed" >&2; (( vid_fail++ )) || true; fi
        done <<< "$vimeo_ids"
        (( OK += vid_ok )) || true
        (( FAIL += vid_fail )) || true
        (( TOTAL += vid_ok + vid_fail - 1 )) || true
        page_handled=true
      fi
    fi

    $page_handled && continue
    # no embedded videos found — fall through to normal pipeline
  fi

  # CDN resolution — rewrite URL to original/largest version
  echo "   resolving CDN..."
  resolved_url="$(cdn_resolve "$url")"

  if [[ "$resolved_url" != "$url" ]]; then
    echo "   CDN resolved → $resolved_url"
    # probe original as fallback (source "O" = pre-resolution, subject to transcode checks)
    echo "   probing baseline (original)..."
    baseline_probe "$url" "O"
    # probe resolved URL
    echo "   probing baseline (resolved)..."
    baseline_probe "$resolved_url"
  else
    echo "   probing baseline..."
    baseline_probe "$url"
  fi

  # use resolved URL for format probing
  probe_url="$resolved_url"

  # capture baseline dimensions for transcode detection (images only)
  if ! $NO_CDN && ! $TRUST_CDN; then
    case "$BASELINE_FMT" in
      tif|png|jpg|webp)
        BASELINE_DIMS="$(_image_dims "$probe_url" "$BASELINE_FMT" 2>/dev/null)" || BASELINE_DIMS=""
        ;;
    esac
  fi

  # determine if baseline is a video/audio format
  is_media=false
  case "$BASELINE_FMT" in
    mp4|webm|mov|mp3|aac|flac|wav|ogg) is_media=true ;;
  esac

  if $is_media; then
    # for video/audio: probe for higher-bitrate variants
    echo "   probing bitrate variants..."
    bitrate_probe "$probe_url"
  elif [[ "$BASELINE_FMT" != "tif" ]]; then
    # short-circuit: if baseline is already TIF, skip further probing
    # Skip Accept/param/path probing for CDNs that ignore them:
    # - WP uploads: server ignores headers and query params
    # - Conde Nast Vulcan: ignores Accept, fm/f/output params, and
    #   extensions; the only working param (?format=) produces palette-
    #   quantized PNGs that are always worse than the native JPEG
    skip_probes=false
    [[ "$probe_url" == *"wp-content/uploads/"* ]] && skip_probes=true
    [[ "$probe_url" =~ media\..+\.com/photos/ ]] && skip_probes=true

    if ! $skip_probes; then
      echo "   probing Accept headers..."
      accept_probe "$probe_url"

      echo "   probing query parameters..."
      param_probe "$probe_url"

      echo "   probing path extensions..."
      path_probe "$probe_url"
    fi
  fi

  # select winner, verify magic bytes, re-select if server lied
  while true; do
    winner="$(select_best)" || {
      echo "   !! SKIP — no valid media format found" >&2
      (( FAIL++ )) || true
      continue 2
    }

    IFS=: read -r _pri _size win_fmt win_source win_url <<< "$winner"
    # reassemble URL (it may contain colons after the source+url fields)
    win_url="${winner#*:*:*:*:}"

    # verify actual content via magic bytes
    echo "   verifying ${win_fmt}..."
    real_fmt="$(verify_magic "$win_url")"
    # internal reclassifications — magic bytes still say the base format
    check_fmt="$win_fmt"
    [[ "$check_fmt" == "png-indexed" ]] && check_fmt="png"
    check_fmt="${check_fmt%-transcode}"
    if [[ "$real_fmt" != "unknown" && "$real_fmt" != "$check_fmt" ]]; then
      echo "   server lied: claims ${win_fmt}, actually ${real_fmt}"
      # remove this fake candidate, fix its entry to reflect real format
      new_candidates=()
      for c in "${CANDIDATES[@]}"; do
        if [[ "$c" == "$winner" ]]; then
          # re-add with corrected format
          real_pri="$(fmt_priority "$real_fmt")"
          new_candidates+=("${real_pri}:${_size}:${real_fmt}:${win_source}:${win_url}")
        else
          new_candidates+=("$c")
        fi
      done
      CANDIDATES=("${new_candidates[@]}")
      continue  # re-select with corrected data
    fi

    # PNG palette demotion: indexed-color PNGs (color type 0x03) are
    # palette-quantized — fewer colors than a full-color JPG. Demote
    # them to "png-indexed" (priority between JPG and WEBP) so a
    # truecolor JPG correctly wins over a palette-crushed PNG.
    if [[ "$win_fmt" == "png" ]] && png_is_indexed "$win_url"; then
      echo "   palette-indexed PNG detected (demoting below JPG)"
      new_candidates=()
      for c in "${CANDIDATES[@]}"; do
        if [[ "$c" == "$winner" ]]; then
          real_pri="$(fmt_priority "png-indexed")"
          new_candidates+=("${real_pri}:${_size}:png-indexed:${win_source}:${win_url}")
        else
          new_candidates+=("$c")
        fi
      done
      CANDIDATES=("${new_candidates[@]}")
      continue  # re-select — a truecolor JPG may now win
    fi

    # ── Transcode detection ───────────────────────────────────────────────
    # If the winner claims a better format than baseline and came from a
    # transcoding-prone probe (Accept header, query param, or pre-resolution
    # URL), verify that dimensions differ. Identical dims = server-side
    # transcode (e.g. JPEG→PNG re-encoding), not a genuine higher-quality
    # source. Convicted candidates are demoted to priority 90.
    if [[ -n "${BASELINE_DIMS}" ]] && ! $TRUST_CDN; then
      win_pri_n="$(fmt_priority "$win_fmt")"
      base_pri_n="$(fmt_priority "$BASELINE_FMT")"

      # only check candidates that claim better format than the resolved baseline,
      # from probes that trigger server-side conversion (A=Accept, P=param, O=pre-resolution)
      if (( win_pri_n < base_pri_n )) && [[ "$win_source" == [APO] ]]; then
        is_transcode=false

        # P1: auto-convict TIF from param probing — no CDN stores TIFFs for web
        if [[ "$win_fmt" == "tif" && "$win_source" == "P" ]]; then
          echo "   TIF via query param — no CDN stores TIFF originals"
          is_transcode=true
        fi

        # P0: dimension comparison — the primary transcode signal
        if ! $is_transcode; then
          win_dims="$(_image_dims "$win_url" "$win_fmt" 2>/dev/null)" || win_dims=""
          if [[ -n "$win_dims" && "$win_dims" == "$BASELINE_DIMS" ]]; then
            echo "   transcode detected: ${win_fmt} has same dims as baseline ${BASELINE_FMT} (${win_dims})"
            is_transcode=true
          fi
        fi

        if $is_transcode; then
          echo "   demoting ${win_fmt} to avoid inflated server-side transcode"
          new_candidates=()
          for c in "${CANDIDATES[@]}"; do
            if [[ "$c" == "$winner" ]]; then
              new_candidates+=("90:${_size}:${win_fmt}-transcode:${win_source}:${win_url}")
            else
              new_candidates+=("$c")
            fi
          done
          CANDIDATES=("${new_candidates[@]}")
          continue  # re-select — baseline or path-probe candidate should win
        fi
      fi
    fi

    break
  done

  # map internal format names to file extensions
  win_ext="$win_fmt"
  [[ "$win_ext" == "png-indexed" ]] && win_ext="png"
  win_ext="${win_ext%-transcode}"
  out="${OUTDIR}/${stem}.${win_ext}"

  # skip if already downloaded with expected size
  if [[ -f "$out" ]] && [[ "$_size" -gt 0 ]] 2>/dev/null; then
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if [[ "$local_size" -eq "$_size" ]]; then
      echo "   SKIP (already exists, ${_size} bytes): $out"
      (( OK++ )) || true
      continue
    fi
  fi

  win_ext_upper="$(echo "$win_ext" | tr '[:lower:]' '[:upper:]')"
  echo "   BEST → ${win_ext_upper} ($(( _size / 1024 )) KB)"
  echo "   downloading → $out"

  # Cloudflare-challenged URLs need curl_cffi (browser TLS) instead of aria2c
  if grep -qF "$win_url" "$CF_BYPASS_FILE" 2>/dev/null; then
    echo "   (Cloudflare bypass via curl_cffi)"
    if cffi_download "$win_url" "$out"; then
      (( OK++ )) || true
    else
      echo "   !! download failed (curl_cffi)" >&2
      (( FAIL++ )) || true
    fi
  elif aria2c -c -x 16 -s 16 -k 1M --header="User-Agent: $UA" -o "$(basename "$out")" -d "$OUTDIR" "$win_url" --quiet; then
    (( OK++ )) || true
  else
    echo "   !! download failed" >&2
    (( FAIL++ )) || true
  fi

done < <(collect_urls)

# summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done. ${OK}/${TOTAL} downloaded, ${FAIL} failed."
echo " Output: ${OUTDIR}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

rm -f "$CF_BYPASS_FILE"
