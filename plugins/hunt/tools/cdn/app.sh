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
JWT_USER_ID=""
JWT_SCOPES=""
JWT_ANONYMOUS="unknown"   # true | false | unknown (payload undecodable)
PREFER_SOURCE="${PREFER_SOURCE:-true}"
ARIA2_CONNECTIONS="${ARIA2_CONNECTIONS:-16}"
FORCE_DOWNLOAD=false
TRUST_CDN=false
MIN_SIZE_MB=150
MIN_SIZE_BYTES=$(( MIN_SIZE_MB * 1024 * 1024 ))
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# Network timeouts (env-overridable). Bound how long a probe/metadata fetch may
# hang so a single unresponsive host can't stall a whole batch. CURL_TIMEOUT_OPTS
# is for short probe/metadata GETs and HEADs; large media downloads use the
# connect timeout only (no max-time cap) since a big video legitimately takes
# a while to transfer.
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
CURL_TIMEOUT_OPTS=(--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME")

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

  # Squarespace / PMC-Photon: server picks WebP for any Accept that includes */*
  # or webp. If the caller didn't already specify an Accept, force one that
  # excludes webp so the original-format file (often JPEG, sometimes PNG) is served.
  if wants_original_accept "$url"; then
    local _h _has_accept=false
    for _h in ${extra_headers[@]+"${extra_headers[@]}"}; do
      [[ "$_h" == Accept:* ]] && { _has_accept=true; break; }
    done
    if ! $_has_accept; then
      extra_headers+=( -H "Accept: $SQUARESPACE_ACCEPT" )
    fi
  fi

  raw="$(curl -sI -L --max-time 10 -H "User-Agent: $UA" ${extra_headers[@]+"${extra_headers[@]}"} "$url" 2>/dev/null)"

  # Cloudflare Polish (lossy) bypass: `cf-polished: ok, orig_size=N` means CF
  # served a cached imgq:85 recompress. The cache key is URL+query, so any
  # unique cfbust value forces a MISS that serves the unmodified origin upload.
  # MISS response carries no cf-polished header and Content-Length == orig_size
  # — both are validators. Runs before is_cf_challenged because a polished 200
  # is mutually exclusive with the cf-mitigated challenge path.
  if $CF_POLISH_BYPASS && printf '%s' "$raw" | grep -qi '^cf-polished:[[:space:]]*ok'; then
    local _orig_size _bust_url _bust_raw _bust_ct _bust_cl
    _orig_size="$(printf '%s' "$raw" | grep -oiE 'orig_size=[0-9]+' | head -n1 | cut -d= -f2)"
    _bust_url="$(cf_polish_bust_url "$url")"
    _bust_raw="$(curl -sI -L --max-time 10 -H "User-Agent: $UA" \
      ${extra_headers[@]+"${extra_headers[@]}"} "$_bust_url" 2>/dev/null)"
    if [[ -n "$_orig_size" ]] && ! printf '%s' "$_bust_raw" | grep -qi '^cf-polished:'; then
      _bust_ct="$(printf '%s' "$_bust_raw" | grep -i '^content-type:' | tail -n1 | tr -d '\r' | awk '{print $2}' | tr -d ';')"
      _bust_cl="$(printf '%s' "$_bust_raw" | grep -i '^content-length:' | tail -n1 | tr -d '\r' | awk '{print $2}')"
      if [[ "$_bust_cl" == "$_orig_size" ]]; then
        echo "$url" >> "$CF_POLISH_FILE"
        printf '%s\n%s\n' "${_bust_ct:-unknown}" "${_bust_cl:-0}"
        return
      fi
    fi
    # Validation failed — fall through to the normal path and live with the
    # polished bytes rather than guess at a size.
  fi

  # Cloudflare managed challenge — TLS fingerprint block.
  # curl can never pass this; retry via curl_cffi (browser TLS impersonation).
  if is_cf_challenged "$raw" && $HAVE_CURL_CFFI; then
    echo "$url" >> "$CF_BYPASS_FILE"
    cffi_head_info "$url"
    return
  fi

  ct="$(printf '%s' "$raw" | grep -i '^content-type:' | tail -n1 | tr -d '\r' | awk '{print $2}' | tr -d ';')"
  cl="$(printf '%s' "$raw" | grep -i '^content-length:' | tail -n1 | tr -d '\r' | awk '{print $2}')"
  local st
  st="$(printf '%s' "$raw" | grep -E '^HTTP/' | tail -n1 | awk '{print $2}')"

  # Akamai Bot Manager block — our spoofed Chrome UA over curl's TLS fingerprint
  # is rejected with 403 text/html (the GET fallback below can't rescue it: it
  # carries the same UA and also 403s). Retry via curl_cffi's browser TLS, which
  # passes. Record the URL in CF_BYPASS_FILE (the "needs browser TLS" set) so the
  # download path routes through cffi_download too. Placed after the CF checks
  # because a Cloudflare challenge and an Akamai 403 are mutually exclusive.
  if is_akamai_bot_blocked "$raw" && $HAVE_CURL_CFFI; then
    echo "$url" >> "$CF_BYPASS_FILE"
    cffi_head_info "$url"
    return
  fi

  # Fall back to a GET probe when HEAD is unusable.  Known cases:
  # 1. Hypebeast/CloudFront+Lambda: HEAD returns content-length: 0
  # 2. Cargo/CloudFront: HEAD returns 403 (text/html) while GET serves the image
  # 3. GOAT/CloudFront: cold-cache HEAD returns 404 with a tiny image/png error
  #    body (CL=118) even though GET serves the asset and warms the edge.
  local need_get=false
  if [[ "${cl:-0}" == "0" && "${ct:-unknown}" != "unknown" ]]; then
    need_get=true
  elif [[ -z "$ct" || "$ct" == "unknown" || "$ct" == text/* ]]; then
    need_get=true
  elif [[ "$st" =~ ^4 ]] && (( ${cl:-0} > 0 && ${cl:-0} <= 1024 )); then
    need_get=true
  fi
  if $need_get; then
    local get_out get_ct2 get_size get_code
    get_out="$(curl -s -o /dev/null -L --max-time 15 -w '%{content_type}\n%{size_download}\n%{http_code}' \
      -H "User-Agent: $UA" ${extra_headers[@]+"${extra_headers[@]}"} "$url" 2>/dev/null)"
    get_ct2="$(sed -n '1p' <<< "$get_out" | awk -F';' '{print $1}')"
    get_size="$(sed -n '2p' <<< "$get_out")"
    get_code="$(sed -n '3p' <<< "$get_out")"
    # When the HEAD signal was a 4xx-with-tiny-body trap, only trust the GET if
    # it returned 2xx — otherwise we'd happily record a real 404 as a successful
    # tiny image. For the older HEAD-failure cases (CL=0, text/*) the existing
    # size>0 check is enough.
    if [[ "${get_size:-0}" != "0" ]]; then
      if [[ "$st" =~ ^4 ]] && ! [[ "$get_code" =~ ^2 ]]; then
        : # GET also failed — leave HEAD's signal intact so caller skips URL
      else
        [[ -n "$get_ct2" ]] && ct="$get_ct2"
        cl="$get_size"
      fi
    fi
  fi

  printf '%s\n%s\n' "${ct:-unknown}" "${cl:-0}"
}

# Quick status code check.  Tries HEAD first; if the server returns 403/405
# (some CDNs block HEAD), retries with GET.
http_status() {
  local extra=()
  wants_original_accept "$1" && extra+=( -H "Accept: $SQUARESPACE_ACCEPT" )
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -I -L --max-time 10 -H "User-Agent: $UA" ${extra[@]+"${extra[@]}"} "$1" 2>/dev/null)"
  if [[ "$code" == "403" || "$code" == "405" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 -H "User-Agent: $UA" ${extra[@]+"${extra[@]}"} "$1" 2>/dev/null)"
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

# File tracking URLs that hit Cloudflare Polish (lossy) — download path must
# apply a fresh cache-buster per phase to bypass the recompressed cache entry.
CF_POLISH_FILE="$(mktemp)"

# Remove the scratch files on ANY exit path — normal completion, a set -e
# abort, or an interrupt (Ctrl-C). Previously a single rm at end-of-script
# leaked both files whenever the run exited early (e.g. `-h`, usage errors).
trap 'rm -f "$CF_BYPASS_FILE" "$CF_POLISH_FILE"' EXIT INT TERM

# Master switch for Polish bypass (env-overridable, mirrors GENERIC_STRIP).
: "${CF_POLISH_BYPASS:=true}"

# Generate a unique cache-buster value. Wall-clock microseconds + two $RANDOM
# draws so back-to-back invocations within the same process never collide.
cf_polish_bust_value() {
  printf '%s%s%s' "${EPOCHREALTIME:-$(date +%s)}" "$RANDOM" "$RANDOM" | tr -d '.'
}

# Append ?cfbust=<rand> (or &cfbust=…) using the existing append_param helper.
cf_polish_bust_url() {
  append_param "$1" "cfbust" "$(cf_polish_bust_value)"
}

# Detect Cloudflare managed challenge in raw HTTP headers.
is_cf_challenged() {
  printf '%s' "$1" | grep -qi 'cf-mitigated:.*challenge'
}

# Detect an Akamai Bot Manager block in raw HTTP headers.
# Some Akamai properties (e.g. press.warnerrecords.com) return 403 to requests
# that CLAIM a browser UA but present curl's TLS ClientHello — the "impersonation
# mismatch" rule. Honest tool UAs (curl/wget) are allowed, but our probes send a
# spoofed Chrome UA ($UA) which is exactly what trips it, so every probe comes
# back 403 text/html and no candidate survives. Unlike Cloudflare there is no
# marker header; the signal is a 403 served by AkamaiGHost. curl_cffi's real
# browser TLS fingerprint (consistent with a browser UA) passes cleanly — verified.
is_akamai_bot_blocked() {
  local raw="$1" status
  status="$(printf '%s' "$raw" | grep -E '^HTTP/' | tail -n1 | awk '{print $2}')"
  [[ "$status" == 403 ]] || return 1
  printf '%s' "$raw" | grep -qi '^server:[[:space:]]*akamai'
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
    image/gif)                echo "gif"  ;;
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
    png-grayscale) echo 4 ;;
    webp)         echo 5 ;;
    gif)          echo 6 ;;
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
  local extra=()
  wants_original_accept "$url" && extra+=( -H "Accept: $SQUARESPACE_ACCEPT" )
  local magic
  magic="$(curl -s -L --max-time 10 -r 0-15 -H "User-Agent: $UA" ${extra[@]+"${extra[@]}"} "$url" 2>/dev/null | xxd -p -l 16)"

  case "$magic" in
    49492a00*)       echo "tif" ;;   # TIFF little-endian
    4d4d002a*)       echo "tif" ;;   # TIFF big-endian
    89504e47*)       echo "png" ;;   # PNG
    ffd8ff*)         echo "jpg" ;;   # JPEG
    47494638*)       echo "gif" ;;   # GIF87a / GIF89a
    52494646*)                        # RIFF — check for WEBP or WAV
      if [[ "$magic" == *"57454250"* ]]; then
        echo "webp"
      elif [[ "$magic" == *"57415645"* ]]; then
        echo "wav"
      else
        echo "unknown"
      fi
      ;;
    0000002066747970*|000000186674797066747970*) echo "mp4" ;; # ftyp box (MP4); first alt subsumes the mp42 variant
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

# Read the PNG color type from IHDR (byte offset 25) and echo a name:
# indexed, grayscale, grayscale-alpha, rgb, rgba, or unknown. Color type 0
# (grayscale) and 3 (indexed) are lossy relative to a color JPG baseline —
# callers can demote them to avoid picking a visually-degraded transcode.
png_color_type() {
  local url="$1"
  local raw
  raw="$(curl -s -L --max-time 10 -r 24-25 "$url" 2>/dev/null | xxd -p -l 2)"
  [[ "${#raw}" -ge 4 ]] || { echo "unknown"; return 1; }
  case "${raw:2:2}" in
    00) echo "grayscale" ;;
    02) echo "rgb" ;;
    03) echo "indexed" ;;
    04) echo "grayscale-alpha" ;;
    06) echo "rgba" ;;
    *)  echo "unknown" ;;
  esac
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
  # mzstatic resizer URLs end in a synthetic spec segment (e.g. /10000x10000.png)
  # that carries no identity — every asset would collide on it. Drop it so the
  # meaningful filename (the segment before the spec) becomes the stem.
  if [[ "$base" =~ ^https?://is[0-9]+(-ssl)?\.mzstatic\.com/image/thumb/.+/[0-9]+x[0-9]+[a-z]*(-[0-9]+)?\.(jpe?g|png|tiff?|webp|bmp)$ ]]; then
    base="${base%/*}"
  fi
  # hdnux (Hearst DAM) URLs end in a fixed rendition name (rawImage.jpg,
  # ratio3x4_960.webp, …) shared by every asset — all would collide on it.
  # Use the photo id (two segments above the rendition) as the stem.
  if [[ "$base" =~ ^https?://s\.hdnux\.com/photos/([0-9]+/){4}([0-9]+)/[0-9]+/[^/]+$ ]]; then
    base="hdnux_${BASH_REMATCH[2]}"
  fi
  # player.vimeo.com progressive_redirect URLs all end in the same literal
  # `file.mp4` — usually percent-encoded with a rendition suffix
  # (`file.mp4%20%28720p%29.mp4`), which is both collision-prone and ugly on
  # disk. Use the video id + rendition from the path instead.
  if [[ "$base" =~ ^https?://player\.vimeo\.com/progressive_redirect/[^/]+/([0-9]+)/rendition/([^/]+)/ ]]; then
    base="vimeo_${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
  fi
  # video.squarespace-cdn.com: the path ends in {variant}, /thumbnail or
  # playlist.m3u8 — none of them a name. Stem on the asset id.
  if [[ "$base" =~ ^https?://video\.squarespace-cdn\.com/content/v1/[A-Za-z0-9]+/([A-Za-z0-9-]+) ]]; then
    base="sqsp_${BASH_REMATCH[1]}"
  fi
  # i.discogs.com (signed imgproxy): the path ends in a chunk of the base64url-
  # encoded S3 source URL — meaningless and collision-prone as a stem. Decode
  # it and use the real source filename (e.g. R-6682162-1424536760-8982).
  if [[ "$base" == *"//i.discogs.com/"* ]]; then
    local dfile
    dfile="$(discogs_source_file "$base" 2>/dev/null)" || dfile=""
    [[ -n "$dfile" ]] && base="$dfile"
  fi
  base="${base##*/}"
  # strip any existing media extension — we'll add the correct one
  base="${base%.[tT][iI][fF]}"
  base="${base%.[tT][iI][fF][fF]}"
  base="${base%.[pP][nN][gG]}"
  base="${base%.[jJ][pP][gG]}"
  base="${base%.[jJ][pP][eE][gG]}"
  base="${base%.[wW][eE][bB][pP]}"
  base="${base%.[gG][iI][fF]}"
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

# ── Facebook lookaside (lookaside.fbsbx.com) media master ────────────────────
# The /elementpath/media/ endpoint transcodes a stored asset on demand; the
# `transcode_extension` query param picks the output codec. Verified behaviour
# (all three render the SAME pixel dimensions — the stored resolution; width/
# dpr/w params are ignored, so that resolution is the ceiling):
#   webp → lossy (what the page requests; ~75 dB vs lossless, smallest sane)
#   jpg  → aggressively recompressed (~30 dB — a quality TRAP, never use)
#   png  → LOSSLESS at native resolution = the master
# Rewriting transcode_extension→png yields the highest-fidelity master with no
# auth (fully public CDN — no cookie/UA/Referer required). The PNG is served as
# `application/octet-stream` with no path extension, which the content-type-
# driven probe pipeline can't classify, so a dedicated intercept fetches it
# directly (see stage_fbsbx_media). Returns the PNG URL, or non-zero if the URL
# is not an interceptable lookaside raster-media request.
#
# Only URLs that already carry transcode_extension are matched: the bare
# media_id+version form (no transcode_extension) serves SVG icons/glyphs that
# must not be force-rasterised to PNG.
fbsbx_png_url() {
  local url="$1"
  [[ "$url" == *"lookaside.fbsbx.com/elementpath/media/"* ]] || return 1
  [[ "$url" == *"media_id="* ]]            || return 1
  [[ "$url" == *"transcode_extension="* ]] || return 1
  sed -E 's/transcode_extension=[A-Za-z0-9]+/transcode_extension=png/' <<< "$url"
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

# Pure helper for vimeo_scrape_embed_ids Strategy 2: pull Vimeo ids out of
# BARE-ID carriers — attributes and JSON-LD fields that hold the numeric id on
# its own, with no player.vimeo.com URL anywhere in the served HTML.
#
# Webflow (and similar CMS) templates bind a "Vimeo ID" collection field to a
# custom attribute whose NAME carries the platform and whose VALUE is the bare
# id — `data-vimeo="1144962023"` — then build the iframe client-side at runtime,
# so no URL-shaped matcher ever sees it. The same field is also templated into
# the page's schema.org VideoObject as `"contentUrl": "<id>"` — an id where a
# URL is expected, which is why that form is invisible too. bodeyco.com carries
# both of these and nothing else; it previously fell through all 9 strategies
# into the image pipeline and died.
#
# Matched, in fallback order:
#   1. data-vimeo-id="<digits>" at any length (the platform's own attribute;
#      pre-2008 ids are 5 digits — pre-existing behaviour, kept verbatim), or
#      a data-*vimeo attribute whose name ENDS at vimeo / -video / -id (any
#      prefix: data-vimeo, data-w3-vimeo, data-vimeo-video-id) with a bare 6+
#      digit value. The suffix is the discriminator: an id carrier's name stops
#      at the platform, while data-vimeo-start / -duration / -width name what
#      they hold — and a 6-digit start offset returned as an id would send
#      handle_vimeo after a stranger's upload and file the real one as _2.
#   2. data-video-id="<digits>" (pre-existing behaviour, kept verbatim)
#   3. JSON-LD "contentUrl": "<6+ digits>" — gated on the page mentioning vimeo
#      at all, since a bare numeric contentUrl names no platform by itself
vimeo_ids_from_data_attrs() {
    local html="$1"
    local ids

    # each `|| true` keeps a declining grep from tripping `set -e` when this
    # helper is called bare (as the offline test harness does)
    # the VALUE is extracted between its quotes: a digit in the attribute
    # NAME (data-w3-vimeo=) must never be read as an id
    ids=$(grep -oiE 'data-vimeo-id="[0-9]+"|data-([a-z0-9]+-)*vimeo(-?video)?(-?id)?="[0-9]{6,}"' <<< "$html" \
        | grep -oE '"[0-9]+"' | tr -d '"' | sort -u || true)
    [[ -n "$ids" ]] && { echo "$ids"; return 0; }

    ids=$(grep -oE 'data-video-id="[0-9]+"' <<< "$html" | grep -oE '[0-9]+' | sort -u || true)
    [[ -n "$ids" ]] && { echo "$ids"; return 0; }

    if grep -qi 'vimeo' <<< "$html"; then
        ids=$(grep -oE '"contentUrl"[[:space:]]*:[[:space:]]*"[0-9]{6,}"' <<< "$html" \
            | grep -oE '[0-9]{6,}' | sort -u || true)
        [[ -n "$ids" ]] && { echo "$ids"; return 0; }
    fi

    return 1
}

# Pure helper for vimeo_scrape_embed_ids Strategy 4: extract Vimeo ids from
# inline JSON data islands that embed api.vimeo.com video objects (Sanity /
# Next.js router preloads, e.g. larkcreative.tv). The only stable marker is
# the API resource URI ("uri":"/videos/<id>/...") — quotes and slashes may be
# backslash-escaped. A preload can carry the site's ENTIRE catalog (observed:
# 209 videos on one page), so when more than one id is present the page URL
# must name the item: each query-param value / fragment / last path segment is
# matched against a "slug":"<value>" field and the video id nearest to that
# slug by byte offset wins (the video object and its slug live in the same
# JSON item; neighboring items are KBs away). Exactly one id → returned as-is.
# Many ids and no slug match → decline (return 1) rather than hand the caller
# a whole portfolio.
vimeo_ids_from_json_island() {
    local html="$1" page_url="$2"

    # "byte_offset:id" per match, in document order
    local uri_matches
    uri_matches=$(printf '%s' "$html" \
        | grep -boE '\\?"uri\\?"[[:space:]]*:[[:space:]]*\\?"\\?/videos\\?/[0-9]{6,}' \
        | sed -E 's|^([0-9]+):.*/([0-9]{6,})$|\1:\2|')
    [[ -z "$uri_matches" ]] && return 1

    local distinct
    distinct=$(echo "$uri_matches" | cut -d: -f2 | sort -u)
    if [[ $(echo "$distinct" | wc -l) -eq 1 ]]; then
        echo "$distinct"
        return 0
    fi

    # Slug candidates from the URL: query-param values, fragment, last path segment
    local candidates cand
    candidates=$( { echo "$page_url" | tr '?&#' '\n' | tail -n +2 | awk -F= '{print $NF}'; \
                    echo "${page_url%%[?#]*}" | grep -oE '[^/]+$'; } | awk 'NF && !seen[$0]++')

    for cand in $candidates; do
        [[ "$cand" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        local slug_off
        slug_off=$(printf '%s' "$html" \
            | grep -boE '\\?"slug\\?"[[:space:]]*:[[:space:]]*\\?"'"$cand"'\\?"' \
            | head -1 | cut -d: -f1)
        [[ -z "$slug_off" ]] && continue
        echo "$uri_matches" | awk -F: -v s="$slug_off" '
            { d = $1 - s; if (d < 0) d = -d; if (best == "" || d < bd) { bd = d; best = $2 } }
            END { if (best != "") print best }'
        return 0
    done
    return 1
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
        html=$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$page_url" -b "$COOKIES" -H "User-Agent: $UA" 2>/dev/null)
    fi
    # Fall back to no cookies if empty or if cookies weren't used
    if [[ -z "$html" ]]; then
        html=$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$page_url" -H "User-Agent: $UA" 2>/dev/null)
    fi

    # Strategy 1: direct iframe src in HTML
    local ids
    ids=$(echo "$html" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)

    # Strategy 2: bare-id carriers — data-*vimeo* / data-video-id attributes and
    # JSON-LD "contentUrl": "<id>" (see vimeo_ids_from_data_attrs)
    if [[ -z "$ids" ]]; then
        ids=$(vimeo_ids_from_data_attrs "$html") || true
    fi

    # Strategy 3: Vimeo IDs in inline JSON/script blocks
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE '"(vimeo_?[Ii]d|video_?[Ii]d|externalId|vimeoVideo)"[[:space:]]*:[[:space:]]*"?[0-9]{6,}"?' \
            | grep -oE '[0-9]{6,}' | sort -u)
    fi

    # Strategy 4: Vimeo API video objects in inline JSON data islands
    # ("uri":"/videos/<id>", escaped or plain; slug-disambiguated when the
    # island preloads a whole catalog — see vimeo_ids_from_json_island)
    if [[ -z "$ids" ]]; then
        ids=$(vimeo_ids_from_json_island "$html" "$page_url") || true
    fi

    # Strategy 5: Vimeo player embed URLs in JavaScript strings (escaped or unescaped)
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'player\.vimeo\.com\\?/video\\?/[0-9]+' | grep -oE '[0-9]{6,}' | sort -u)
    fi

    # Strategy 6: Squarespace ?format=json API
    if [[ -z "$ids" ]]; then
        local base_url="${page_url%%#*}"
        local json_html
        json_html=$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "${base_url}?format=json" -H "User-Agent: $UA" 2>/dev/null)
        ids=$(echo "$json_html" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)
        if [[ -z "$ids" ]]; then
            ids=$(echo "$json_html" | grep -oE '"(vimeoId|externalId|videoId)"[[:space:]]*:[[:space:]]*"?[0-9]{6,}"?' \
                | grep -oE '[0-9]{6,}' | sort -u)
        fi
    fi

    # Strategy 7: look for vimeo.com/{id} patterns in page data
    if [[ -z "$ids" ]]; then
        ids=$(echo "$html" | grep -oE 'vimeo\.com/[0-9]{6,}' | grep -oE '[0-9]+' | sort -u)
    fi

    # Strategy 8: for SPAs with hash routes, try the page path as a slug
    if [[ -z "$ids" ]] && echo "$page_url" | grep -q '#/'; then
        local slug
        slug=$(echo "$page_url" | sed 's/.*#\///' | sed 's/\/$//')
        local slug_url="${page_url%%#*}${slug}/?format=json"
        local slug_json
        slug_json=$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$slug_url" -H "User-Agent: $UA" 2>/dev/null)
        ids=$(echo "$slug_json" | grep -oE 'player\.vimeo\.com/video/[0-9]+' | grep -oE '[0-9]+' | sort -u)
    fi

    # Strategy 9: query param hints — try common CMS API patterns
    if [[ -z "$ids" ]]; then
        local api_paths=()
        local path_part
        path_part=$(echo "$page_url" | sed 's|https\?://[^/]*||')
        api_paths+=("${origin}/api${path_part}")
        api_paths+=("${origin}/api/v1${path_part}")
        for api_url in "${api_paths[@]}"; do
            local api_resp
            api_resp=$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$api_url" -H "User-Agent: $UA" -H "Accept: application/json" 2>/dev/null)
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
    viewer_json=$(curl -s "${CURL_TIMEOUT_OPTS[@]}" -b "$COOKIES" \
        -H "Accept: application/json" \
        -H "User-Agent: $UA" \
        "https://vimeo.com/_next/viewer" 2>/dev/null)

    JWT=$(echo "$viewer_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jwt',''))" 2>/dev/null)

    if [[ -z "$JWT" ]]; then
        verr "Failed to acquire JWT. Check your cookies file."
        return 1
    fi

    # Decode the JWT payload once: expiry, user_id and scopes drive both the
    # expiry-refresh check and the anonymous-cookie diagnostic below. The
    # decoder's exit status is KEPT: an undecodable payload (python3 missing, a
    # claim renamed upstream) must read as UNKNOWN, never as anonymous — or an
    # authenticated cookie jar would be demoted to the transcode ladder on a
    # decode hiccup, with a diagnosis that blames the operator's login.
    local jwt_meta
    JWT_ANONYMOUS="unknown"
    if jwt_meta=$(echo "$JWT" | python3 -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
print(d.get('exp', 0))
print(d.get('user_id') if d.get('user_id') is not None else '')
print(d.get('scopes', ''))
" 2>/dev/null); then
        { read -r JWT_EXPIRY; read -r JWT_USER_ID; read -r JWT_SCOPES; } <<< "$jwt_meta" || true
        # A JWT minted from cookies that carry no login session is scope=public /
        # user_id=null. Vimeo removed download/files/play from the public scope,
        # so the API source path CANNOT work with anonymous cookies.
        if [[ -z "$JWT_USER_ID" ]] || [[ "$JWT_SCOPES" != *video_files* ]]; then
            JWT_ANONYMOUS=true
        else
            JWT_ANONYMOUS=false
        fi
    else
        JWT_EXPIRY=0; JWT_USER_ID=""; JWT_SCOPES=""
    fi

    if [[ "$JWT_EXPIRY" =~ ^[0-9]+$ ]] && (( JWT_EXPIRY > 0 )); then
        vok "JWT acquired (expires $(date -r "$JWT_EXPIRY" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$JWT_EXPIRY"))"
    else
        vok "JWT acquired (expiry unknown — payload not decoded)"
    fi

    case "$JWT_ANONYMOUS" in
      true)
        # warn once, loudly, instead of letting it fail later with the cryptic
        # "No download/files fields" (the callers that silence stderr get the
        # reason appended to their own fallback line via vimeo_api_unavailable_why)
        vwarn "Cookies are ANONYMOUS (scope='${JWT_SCOPES:-public}', no user session)."
        vwarn "The API source-master path needs authenticated cookies with the 'video_files' scope."
        vwarn "Re-export cookies.txt while logged in to vimeo.com; otherwise the ceiling is the"
        vwarn "config/yt-dlp transcode ladder (typically ≤1080p), not the uploaded source."
        ;;
      unknown)
        vwarn "Could not decode the JWT payload — cannot tell whether the cookies carry a login session; trying the API anyway."
        ;;
    esac
}

# One-line reason for an "API unavailable" fallback, for callers that run
# vimeo_process_api with stderr silenced (the anonymous warning above never
# reaches them). Empty when there is nothing to add.
vimeo_api_unavailable_why() {
    [[ "$JWT_ANONYMOUS" == true ]] && printf ' (cookies are anonymous: no video_files scope)'
    return 0
}

# ── Vimeo API path ──────────────────────────────────────────────────────────

vimeo_fetch_info() {
    local video_id="$1"
    local unlisted_hash="${2:-}"
    local api_id="$video_id"
    if [[ -n "$unlisted_hash" ]]; then
        api_id="${video_id}:${unlisted_hash}"
    fi
    curl -s "${CURL_TIMEOUT_OPTS[@]}" \
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

    curl -s "${CURL_TIMEOUT_OPTS[@]}" "https://player.vimeo.com/video/${video_id}" \
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

    # Vimeo's progressive_redirect URLs sometimes return 302 with empty Location
    # (storage backend missing the asset — common for older "source" originals).
    # Probe with HEAD first so we can return exit code 2 (dead-link) and let the
    # caller pick a different rendition before falling all the way back to yt-dlp.
    local probe_headers probe_status probe_location
    probe_headers=$(curl -sI "${CURL_TIMEOUT_OPTS[@]}" "$url" \
        -H "User-Agent: $UA" \
        -H "Referer: https://vimeo.com/" \
        -b "$COOKIES" 2>/dev/null)
    probe_status=$(echo "$probe_headers" | awk 'NR==1 {print $2}')
    probe_location=$(echo "$probe_headers" | awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[Ll]ocation:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}')
    if [[ "$probe_status" == "302" || "$probe_status" == "301" ]] && [[ -z "$probe_location" ]]; then
        vwarn "Dead Vimeo redirect (HTTP $probe_status, empty Location) — asset not in storage"
        return 2
    fi

    local encoded_url
    encoded_url=$(python3 -c "
import sys, urllib.parse
url = sys.stdin.read().strip()
p = urllib.parse.urlparse(url)
safe_path = urllib.parse.quote(urllib.parse.unquote(p.path), safe='/:@!&=+,;')
print(urllib.parse.urlunparse((p.scheme, p.netloc, safe_path, p.params, p.query, p.fragment)))
" <<< "$url")

    # Try aria2c first (fast, multi-connection)
    if aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" \
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
    curl -fL -# --connect-timeout "$CURL_CONNECT_TIMEOUT" \
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

    # Anonymous JWT: the API cannot return download/files (Vimeo dropped them from
    # the public scope). Skip straight to the config/yt-dlp fallback rather than
    # burn an API round-trip. Only a DECODED anonymous payload skips: an
    # undecodable one is unknown, and unknown still gets its API attempt.
    if [[ "$JWT_ANONYMOUS" == true ]]; then
        return 1
    fi

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
        print('No download/files in API response (video files not exposed for this asset)')
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

    local PREFER_SOURCE="$PREFER_SOURCE"
    local attempted_source=false

    while :; do
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
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            vok "Downloaded: ${OUTDIR}/${dl_filename}"
            return 0
        fi

        # Exit code 2 = dead progressive_redirect (storage missing). If we just
        # tried the source rendition, fall back to the best transcode from the
        # same API response before giving up to the player-config path.
        if [[ $rc -eq 2 ]] && [[ "$PREFER_SOURCE" == "true" ]] && [[ "$attempted_source" == "false" ]]; then
            attempted_source=true
            PREFER_SOURCE=false
            vwarn "Source rendition unavailable — retrying with best transcode"
            continue
        fi

        verr "Download failed: $dl_filename"
        return 1
    done
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
        prog_size=$(curl -sI -L "${CURL_TIMEOUT_OPTS[@]}" "$dl_url" -H "User-Agent: $UA" 2>/dev/null \
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
            vwarn "API unavailable for $video_id$(vimeo_api_unavailable_why) — trying player config path"
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

# Substack delivers every post image through a Cloudinary "fetch" proxy at
# substackcdn.com/image/fetch/<transform>/<urlencoded-origin>. The transform
# segment carries f_auto + a w_<N> cap + a signed $s_!...! token, so the bytes
# the page actually paints are a small, downscaled, LOSSY webp/jpeg — even when
# the origin (and the page's own metadata) advertises the asset as a .tif.
# (Verified: a 1456x2151 CMYK master served to the page as a 398 KB JPEG, ~62x
# smaller than the 24.6 MB origin.) The embedded origin is the bare, unsigned,
# un-watermarked, full-resolution upload on substack-post-media.s3.amazonaws.com
# (public/world-readable) — that S3 object IS the master. Strip the proxy and
# return the decoded origin; the normal baseline probe then fetches it losslessly.
# Substack's S3 keys are canonical: bare <uuid>.<ext> and <uuid>_WxH.<ext> are
# distinct uploads (stripping the _WxH suffix 403s), so we never touch the key.
cdn_resolve_substack() {
  local url="$1"
  [[ "$url" == *"substackcdn.com/image/fetch/"* ]] || return 1

  # After /image/fetch/ comes "<transform>/<encoded-origin>"; the transform is a
  # single comma-delimited segment with no slash, so one #*/ peels it off. The
  # encoded origin's own slashes are percent-escaped (%2F), so nothing else goes.
  local after encoded
  after="${url#*/image/fetch/}"
  encoded="${after#*/}"
  [[ -n "$encoded" ]] || return 1

  # The origin must itself be an (optionally percent-encoded) http(s) URL.
  case "$encoded" in
    http%3[Aa]*|https%3[Aa]*|http://*|https://*) ;;
    *) return 1 ;;
  esac

  # URL-decode (%3A -> :, %2F -> /, ...) the same way cdn_resolve_nextjs does.
  local decoded
  decoded="$(printf '%b' "${encoded//%/\\x}")"
  echo "$decoded"
}

# www.playboy.com is a WordPress/WooCommerce site whose EDITORIAL images are
# re-hosted Substack uploads: /wp-content/uploads/<YYYY>/<MM>/<uuid>_WxH[-resize][-N].webp
# where <uuid>_WxH is the verbatim Substack S3 key and the leading WxH is the
# ORIGINAL upload resolution. WordPress (a) re-encodes to lossy webp, (b)
# DOWNSCALES even the "full" file to a 1456px-wide column copy (the _3552x5327
# name is inherited, NOT the stored pixels — verified decode: 1456x2184), and
# (c) emits a ladder of -WxH srcset crops. So every playboy.com rendition is a
# lossy, downscaled derivative. The true master is the same key on Substack's
# public bucket: substack-post-media.s3.amazonaws.com/public/images/<uuid>_WxH.<ext>
# (verified: 3552x5327 q95 4.7MB JPEG vs the site's 1456px 228KB webp — 2.4x the
# linear resolution). Reconstruct the S3 key from the filename and hand back the
# master. Default ext is .jpeg (100% of observed editorial uploads); path_probe
# then ext-swaps on the S3 host to catch the rare .png/.tif upload (e.g. a CMYK
# scan, as in the Hooters feature). Only the <uuid>_WxH pattern is matched, so
# theme assets / WooCommerce product images (no Substack UUID) fall through.
cdn_resolve_playboy() {
  local url="$1"
  [[ "$url" == *"playboy.com/wp-content/uploads/"* ]] || return 1

  local base="${url##*/}"
  base="${base%%\?*}"

  # <uuid>_WxH, discarding any -<w>x<h> resize, -<N> dedup suffix, and extension.
  local key
  key="$(echo "$base" | grep -oE \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_[0-9]+x[0-9]+')"
  [[ -n "$key" ]] || return 1

  echo "https://substack-post-media.s3.amazonaws.com/public/images/${key}.jpeg"
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
    png|png-indexed|png-grayscale)
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

# Penske Media (PMC) WordPress VIP + Jetpack Photon — Rolling Stone, Variety,
# WWD, IndieWire, SheKnows. The bare upload URL is the untouched original master
# (full EXIF); the page paints it through Photon, which downscales/recompresses
# whenever ANY query param is present (?w=/?resize=/?crop=/?quality=/?strip=) and
# transcodes to lossy webp whenever the Accept header allows webp. This resolver
# handles the param lever — strip ALL query params back to the bare upload URL.
# The webp lever is handled separately by is_pmc_photon()/wants_original_accept(),
# which inject a no-webp Accept in head_info/http_status/verify_magic/download.
# Runs BEFORE cdn_resolve_wp_uploads so the bare-master rewrite wins over that
# resolver's filename-suffix stripping (which would misfire on real -N frame
# names like Nasseri-RS-Friedland-Final-1.jpg). No-op (return 1) on an already
# bare URL — the dispatcher keeps the original as a candidate either way.
cdn_resolve_pmc() {
  local url="$1"
  is_pmc_photon "$url" || return 1
  [[ "$url" == *"?"* ]] || return 1               # already bare — nothing to do
  local base="${url%%\?*}"
  echo "$base" | grep -qiE '\.(jpe?g|png|gif|webp|tiff?)$' || return 1
  echo "$base"
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
  # Order matters: dimensions outermost, then -e<ts>, then -scaled, then collision.
  #   e.g. 7-1-scaled-500x375.jpg → 7-1-scaled → 7-1 → 7
  #
  # -WxH, -e<ts> and -scaled are SAFE: WordPress derives all three from the
  # same parent attachment, so the stripped stem is always the same lineage.
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

  # 2. Strip the WP image-editor suffix  (-e<unix-ts>)
  # Saving a crop/rotate/scale in the WP editor writes <stem>-e<ts>.<ext>
  # beside the untouched parent. The parent is a superset of the edit — same
  # lineage, more pixels — but a CROP edit changes the aspect ratio, so this
  # deliberately skips _same_image verification (which would reject it).
  stripped="$(echo "$current" | sed -E 's/-e[0-9]{10,}$//')"
  if [[ "$stripped" != "$current" ]]; then
    safe_candidates+=("$stripped")
    current="$stripped"
  fi

  # 3. Strip -scaled  (WP ≥5.3 big-image threshold)
  if [[ "$current" == *-scaled ]]; then
    current="${current%-scaled}"
    safe_candidates+=("$current")
  fi

  # 4. Strip collision suffix  (-N, single digit — WP duplicate-name rename)
  stripped="$(echo "$current" | sed -E 's/-([0-9])$//')"
  if [[ "$stripped" != "$current" ]]; then
    collision_candidates+=("$stripped")
  fi

  (( ${#safe_candidates[@]} + ${#collision_candidates[@]} == 0 )) && return 1

  # HEAD-check each candidate; return the largest valid one
  local best_url="" best_size=0
  local seen=""

  # Process safe candidates, MOST-STRIPPED FIRST — the first one that exists wins.
  #
  # WordPress guarantees a strict containment ladder: original ⊇ -scaled ⊇ -WxH,
  # so the most-stripped stem is always the largest in PIXELS. Byte size is not
  # a usable proxy: -scaled is a fresh q82 re-encode and routinely outweighs a
  # more efficiently compressed original (observed on playboy.com — a 3089x2048
  # original at 432 KB vs its own 2560x1697 -scaled copy at 626 KB). Ranking by
  # Content-Length here would hand back the downscaled derivative.
  local i
  for (( i = ${#safe_candidates[@]} - 1; i >= 0; i-- )); do
    local c="${safe_candidates[$i]}"
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
    (( cl > 0 )) || continue

    best_size="$cl"
    best_url="$candidate_url"
    break
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
  info="$(curl -sI -L "${CURL_TIMEOUT_OPTS[@]}" "$url" 2>/dev/null)"
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
    echo "$url" | sed -E 's/name=[^&]*/name=orig/'
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

cdn_resolve_reddit_preview() {
  local url="$1"
  # preview.redd.it is Reddit's signed lossy resizer: every rendition carries
  # `?width=N&…&s=<sig>` and the signature covers the params, so stripping them
  # 403s. The stored master is the same media id on i.redd.it (public, plain
  # curl, no params; EXIF is stripped at ingest so it IS the public ceiling).
  # Two basename forms map to the id:
  #   <seo-slug>-v0-<media_id>.<ext>   (2023+ slugged form; id after last -v0-)
  #   <media_id>.<ext>                 (bare form: old posts, selftext inlines)
  # Subpath assets (award_images/, awards/, emotes) are UI chrome, not post
  # media, and have no i.redd.it sibling — reject anything with a / in the key.
  # external-preview.redd.it is an opaque proxy key for an off-site origin and
  # is NOT resolvable from the URL alone — no match.
  [[ "$url" =~ ^https?://preview\.redd\.it/ ]] || return 1

  local key="${url#*preview.redd.it/}"
  key="${key%%\?*}"
  [[ "$key" == */* ]] && return 1
  [[ "$key" == *.* ]] || return 1

  local name="${key%.*}" ext="${key##*.}"
  case "$ext" in jpg|jpeg|png|gif|webp) : ;; *) return 1 ;; esac

  local id="$name"
  [[ "$name" == *-v0-* ]] && id="${name##*-v0-}"
  [[ "$id" =~ ^[A-Za-z0-9]{8,24}$ ]] || return 1

  echo "https://i.redd.it/${id}.${ext}"
}

# ── Discogs (i.discogs.com) — signed imgproxy → API full-size uri ────────────
# i.discogs.com is a SIGNED imgproxy deployment:
#   https://i.discogs.com/<sig>/rs:fit/g:sm/q:90/h:600/w:595/<b64url source>.jpeg
# The trailing path segments are base64url (split every 16 chars, unpadded) of
# the S3 source, e.g. s3://discogs-database-images/R-6682162-1424536760-8982.jpeg.
# The signature covers the WHOLE path (processing options + payload + format
# extension): any tamper — bumping h:/w:, swapping .jpeg→.png, the `unsafe`
# placeholder — returns 403, so no rendition can be forged. Query params are
# NOT covered (silently ignored, byte-identical response), so param probing
# only duplicates the baseline. The S3 bucket is private (403), the release
# pages are Cloudflare-403'd even to curl_cffi, and every legacy host
# (img.discogs.com raw filenames, api.discogs.com/images, s.pixogs.com) is dead.
#
# The one open surface is the UNAUTHENTICATED API (a User-Agent header is
# required; ~25 req/min — use PROBE_DELAY on big batches):
# api.discogs.com/{releases,artists,labels,masters}/<id> returns images[] with
# `uri` = the signed FULL-SIZE rendition (q:90 at the stored dims) and
# `uri150` = the 150px thumb. Discogs resizes every upload to max 600px on the
# long edge (verified: 2025-era releases still store 600×600), so the API uri
# IS the platform ceiling — no higher tier exists anywhere.
#
# Resolver: decode the payload → source filename `<R|A|L|M>-<id>-…` → map the
# prefix to its API endpoint → fetch → return the images[] uri whose payload
# matches ours. This upgrades any thumb/derived rendition (uri150, search
# thumbs) to the full-size uri; a URL that already is the full uri round-trips
# unchanged (the dispatcher treats it as a no-op).
is_discogs_image_url() {
  [[ "$1" == *"//i.discogs.com/"* ]]
}

# Joined base64url payload (slashes removed, format extension dropped) from an
# i.discogs.com URL — pure string transform; also the match key for API uris.
discogs_b64_payload() {
  local url="$1"
  is_discogs_image_url "$url" || return 1
  local path="${url#*//i.discogs.com/}"
  path="${path%%\?*}"
  path="${path#*/}"                      # drop the signature segment
  while [[ "$path" == */* && "${path%%/*}" == *:* ]]; do
    path="${path#*/}"                    # drop imgproxy processing options
  done
  local payload="${path//\//}"           # re-join the split base64 segments
  payload="${payload%.*}"                # drop the format ext (b64 has no '.')
  [[ -n "$payload" && "$payload" != *:* ]] || return 1
  echo "$payload"
}

# Decoded S3 source filename (e.g. R-6682162-1424536760-8982.jpeg) from an
# i.discogs.com URL. The payload is base64url and unpadded — translate the
# alphabet and re-pad before decoding, otherwise base64 silently drops the
# final partial group. Rejects payloads outside the discogs-database-images
# bucket. (-d/-D fallback covers GNU and older BSD/macOS base64.)
discogs_source_file() {
  local url="$1" payload b64 pad decoded
  payload="$(discogs_b64_payload "$url")" || return 1
  b64="$(printf '%s' "$payload" | tr '_-' '/+')"
  pad=$(( (4 - ${#b64} % 4) % 4 ))
  while (( pad > 0 )); do b64+="="; pad=$((pad - 1)); done
  decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" \
    || decoded="$(printf '%s' "$b64" | base64 -D 2>/dev/null)" || return 1
  [[ "$decoded" == s3://discogs-database-images/* ]] || return 1
  echo "${decoded#s3://discogs-database-images/}"
}

cdn_resolve_discogs() {
  local url="$1"
  is_discogs_image_url "$url" || return 1
  local file payload endpoint id
  file="$(discogs_source_file "$url")" || return 1
  payload="$(discogs_b64_payload "$url")" || return 1
  case "$file" in
    R-*) endpoint="releases" ;;
    A-*) endpoint="artists"  ;;
    L-*) endpoint="labels"   ;;
    M-*) endpoint="masters"  ;;
    *)   return 1 ;;
  esac
  id="${file#?-}"
  id="${id%%-*}"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  local json
  json="$(curl -s "${CURL_TIMEOUT_OPTS[@]}" -H "User-Agent: $UA" \
    "https://api.discogs.com/${endpoint}/${id}" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  # only full-size `"uri"` keys — the regex does not match `"uri150"`
  local cand cpay
  while IFS= read -r cand; do
    cpay="$(discogs_b64_payload "$cand" 2>/dev/null)" || continue
    if [[ "$cpay" == "$payload" ]]; then
      echo "$cand"
      return 0
    fi
  done < <(grep -oE '"uri": *"[^"]*"' <<< "$json" | sed -E 's/^"uri": *"//; s/"$//')
  return 1
}

cdn_resolve_hdnux() {
  local url="$1"
  # s.hdnux.com is Hearst Newspapers' photo DAM (SFGate, SF Chronicle, Houston
  # Chronicle, statesman.com post-Hearst-acquisition, …), Fastly-fronted.
  # URL anatomy:
  #   s.hdnux.com/photos/<aa>/<bb>/<cc>/<dd>/<photo_id>/<version>/<rendition>
  # Every named rendition (ratio3x4_960.webp, square_small.jpg, landscape_*,
  # NxM.jpg, …) is a lossy derived crop/downscale. The stored master is the
  # fixed rendition name rawImage.jpg — verified 5.2× the page-painted webp,
  # at the photo's full native dims (the CMS's own declared width/height).
  # Query params are ignored (identical Content-Length), rawImage has no
  # Accept-driven transcode (vary: Fastly-SSL only), and unknown rendition
  # names 302 to version 3 of the same path — not a fallback surface, so no
  # format ladder exists above rawImage.jpg. rawImage is EXIF-stripped at
  # ingest and the DAM caps uploads at ~2048px long edge, so it IS the public
  # ceiling. The version segment is kept as given: raw bytes are version-
  # stable (v3 == v5 byte-identical on tested assets) and the page always
  # references the current version.
  [[ "$url" =~ ^(https?://s\.hdnux\.com/photos/([0-9]+/){4}[0-9]+/[0-9]+/)[^/?]+\.(jpe?g|png|webp|gif)(\?.*)?$ ]] || return 1
  local prefix="${BASH_REMATCH[1]}"
  local rendition="${url##*/}"; rendition="${rendition%%\?*}"
  # already the master and param-free → nothing to rewrite
  [[ "$rendition" == "rawImage.jpg" && "$url" != *\?* ]] && return 1
  echo "${prefix}rawImage.jpg"
}

# Future PLC's CMS media CDN. `cdn.mos.cms.futurecdn.net` serves imagery for
# every Future title — TechRadar, Tom's Guide, PC Gamer, GamesRadar, Marie
# Claire, Who What Wear, Livingetc, Space.com, LiveScience … — as CloudFront →
# Varnish → an image service Future calls "kodiak" (`x-ftr-backend-server:
# sse-prod:kodiak`) in front of an S3 origin (a bad key returns S3's own
# `NoSuchKey` XML for `/proof/<key>`).
#
# TWO unsigned rendition grammars sit on top of one stored object:
#   1. `<id>-<width>-<quality>.<ext>`                    — downscale + re-encode
#   2. `/v2/t:<top>,l:<left>,cw:<w>,ch:<h>,q:<q>,w:<w>/<id>.<ext>` — CROP + resize
# and either may carry a trailing `.webp`, which is an explicit path suffix
# rather than Accept negotiation (no `vary` header). Both are strippable.
#
# The master is the bare `<id>.<ext>` — the stored upload itself:
#   • `-99999-100` clamps to the stored dims on every asset tested, so there is
#     no upscale trap and bare dims == source dims.
#   • On PNG sources bare is raw-pixel-identical to the rendition (same rgba
#     md5) yet a distinct object (differing deflate bytes) — kodiak re-encodes.
#   • On JPEG sources bare matches NO point on kodiak's quality ladder (bare
#     388,791 B vs q85 351,411 / q86 364,305 / q90 461,914 at identical dims),
#     i.e. it is the stored file, not a derived rendition. `-99999-100` is a
#     2.8×-larger re-encode OF it at PSNR 55.6 dB — a pure bloat trap.
#   • The `/v2/` form CROPS (`l:437,cw:1125` carves a 1125×1125 square out of a
#     2000×1125 master), so stripping it also recovers the uncropped frame.
# The win is largest when the page asked for a thumbnail: a `-140-80.jpg` rung
# (140×182, 7.5 KB) resolves to the 2310×3000 / 1.97 MB master.
#
# The extension is locked to the stored object's format — `.jpg`, `.tif` and
# `.webp` on a PNG asset all 404 — so no transcode surface and no wrapper trap
# exists, and query params are ignored outright (byte-identical response). The
# whole Accept/param/path ladder is therefore suppressed via
# is_futurecdn_image_url in stage_probe_formats: it could only ever yield dead
# or duplicate candidates.
# ── TownNews / BLOX Digital (TNCMS) ──────────────────────────────────────────
# The CMS behind ~2000 US local-news sites (nola.com, theadvocate.com,
# stltoday.com, tucson.com, richmond.com, tulsaworld.com, omaha.com, …), served
# via bloximages.<region>.vip.townnews.com in front of <publication>/content/tncms/.
#
# BLOX downscales EVERY editorial upload to a fixed AREA of 2,073,600 px
# (= 1920x1080) preserving aspect ratio — verified across a 16-photo gallery
# whose landscape (1915x1082) and portrait (1246x1664) frames all land on the
# same 2.07 MP area, spread 0.15%. That capped `.image.jpg` is the ONLY
# rendition the page, the srcset, the JSON-LD and the og:image ever reference.
#
# But the CMS also stores the photographer's full-resolution delivery as a
# SECOND resource, `<hash>.hires.jpg` — up to 20.6x the pixels (7994x5332 off a
# Canon R5 II), Q91 vs Q80, with EXIF/IPTC intact. The string "hires" appears
# nowhere in the article HTML or the image permalink page, and its resource
# hash is NOT derivable from the .image.jpg hash (…91e06 → …9330b share only
# the leading timestamp), so no pure string rewrite can reach it. It is only
# discoverable through the site's public, auth-free BLOX search API:
#   https://<publication>/search/?f=json&t=image&l=1&q=uuid:<asset-uuid>
# whose row carries hi_res.{resource_url,width,height,file_size}.
#
# TRAPS this replaces: the bloximages resizer UPSCALES without clamping
# (?resize=4000 on an 1905px source returns real 4000x2282 interpolated pixels,
# 1.8x the bytes — PSNR 33.2 dB vs true 4000px detail), and ?quality=100 is
# silently ignored (md5-identical to bare). Bare on bloximages is itself a Q63
# EXIF-stripped re-encode; the publication host serves Q80 with EXIF.
is_tncms_image_url() {
  [[ "$1" == *"/content/tncms/assets/"* ]]
}

# Pure: asset uuid out of a TNCMS asset path.
tncms_asset_uuid() {
  local url="${1%%\?*}"
  [[ "$url" =~ /content/tncms/assets/v3/[^/]+/[^/]+/[^/]+/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Pure: the publication host that owns the asset. bloximages fronts the real
# site as the FIRST path segment (bloximages.newyork1.vip.townnews.com/nola.com/
# content/tncms/…), so the CDN host is never the API host.
tncms_site_host() {
  local rest="${1#*://}"; rest="${rest%%\?*}"
  local host="${rest%%/*}"
  if [[ "$host" == bloximages.*.vip.townnews.com ]]; then
    local tail="${rest#*/}"
    host="${tail%%/content/tncms/*}"
  fi
  [[ "$host" == *.* && "$host" != */* ]] || return 1
  printf '%s\n' "$host"
}

# Runtime helper (network): .image.jpg → the hi_res master via the BLOX search
# API. Echoes the master URL; sets TNCMS_ASSET_TITLE to the CMS's own filename
# so the download keeps the photo-desk name rather than an opaque hash stem.
tncms_hires_master() {
  local url="$1" uuid host json hires title
  is_tncms_image_url "$url" || return 1
  [[ "$url" == *".hires."* ]] && return 1   # already the master
  uuid="$(tncms_asset_uuid "$url")" || return 1
  host="$(tncms_site_host "$url")" || return 1

  # -L is required: several BLOX sites 301 the bare host to www.
  json="$(curl -s "${CURL_TIMEOUT_OPTS[@]}" -L -A "$UA" \
    "https://${host}/search/?f=json&t=image&l=1&q=uuid:${uuid}" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1

  # Isolate the hi_res object (flat — no nested braces) and read its resource_url.
  hires="$(printf '%s' "$json" \
    | sed -n 's/.*"hi_res"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
    | grep -oE '"resource_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' | head -1)"
  # The BLOX API escapes every forward slash (https:\/\/…); unescape via sed —
  # a ${//} substitution can't express the pattern without the `/` delimiter
  # swallowing the escape.
  hires="$(printf '%s' "$hires" | sed 's#\\/#/#g')"
  [[ "$hires" == http*://*"/content/tncms/assets/"*".hires."* ]] || return 1

  title="$(printf '%s' "$json" \
    | grep -oE '"title"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/' | head -1)"

  # Two lines — line 1 the master URL, line 2 the CMS filename. A global can't be
  # used: the caller invokes this inside $(…), so any assignment dies with the
  # subshell (same reason head_info returns its fields as lines).
  printf '%s\n%s\n' "$hires" "${title:-}"
}

is_futurecdn_image_url() {
  [[ "$1" == *"//cdn.mos.cms.futurecdn.net/"* ]]
}

cdn_resolve_futurecdn() {
  local url="$1"
  is_futurecdn_image_url "$url" || return 1
  local stripped="${url%%\?*}"
  local prefix="${stripped%%//cdn.mos.cms.futurecdn.net/*}//cdn.mos.cms.futurecdn.net"
  local path="${stripped#*//cdn.mos.cms.futurecdn.net}"
  # drop a /v2/<transform-list>/ prefix (crop + resize + quality); the trailing
  # capture keeps any remaining sub-path, e.g. /v2/<t>/flexiimages/<name>.png
  if [[ "$path" =~ ^/v2/[^/]*:[^/]*/(.+)$ ]]; then
    path="/${BASH_REMATCH[1]}"
  fi
  # drop the explicit .webp delivery suffix, but only where it wraps a real
  # source extension — a genuinely webp-sourced asset is bare `<id>.webp`
  if [[ "$path" =~ ^(.+\.(png|jpe?g|gif))\.webp$ ]]; then
    path="${BASH_REMATCH[1]}"
  fi
  # drop the -<width>-<quality> rendition suffix
  if [[ "$path" =~ ^(.+)-[0-9]+-[0-9]+(\.[A-Za-z0-9]+)$ ]]; then
    path="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  local result="${prefix}${path}"
  [[ "$result" == "$url" ]] && return 1
  echo "$result"
}

# Extract the base36 post id from any Reddit post URL form:
#   /r/<sub>/comments/<id>[/slug…], /user/<u>/comments/<id>, /comments/<id>,
#   /gallery/<id>, and the redd.it/<id> shortlink. Share links
#   (/r/<sub>/s/<token>) carry no id — the caller resolves the redirect first.
reddit_post_id_from_url() {
  local url="$1" id=""
  case "$url" in
    *reddit.com/*/comments/*|*reddit.com/comments/*)
      id="$(echo "$url" | sed -E 's#.*/comments/([a-z0-9]+).*#\1#')" ;;
    *reddit.com/gallery/*)
      id="$(echo "$url" | sed -E 's#.*/gallery/([a-z0-9]+).*#\1#')" ;;
    http://redd.it/*|https://redd.it/*)
      id="$(echo "$url" | sed -E 's#.*redd\.it/([a-z0-9]+).*#\1#')" ;;
  esac
  [[ "$id" =~ ^[a-z0-9]{5,9}$ ]] || return 1
  echo "$id"
}

cdn_resolve_ynap() {
  local url="$1"
  # YOOX NET-A-PORTER group: Mr Porter, Net-a-Porter
  [[ "$url" =~ cache\.(mrporter|net-a-porter)\.com/ ]] || return 1

  # Variant-style URL: /variants/images/{id}/{variant}/w{W}_q{Q}.{ext}
  # Quality is whitelisted server-side — only q60 returns data, so keep it.
  if [[ "$url" =~ /variants/images/ ]]; then
    echo "$url" | sed -E 's|/w[0-9]+_q[0-9]+\.|/w2000_q60.|'
    return 0
  fi

  # Product-style URL: /images/products/{id}/{id}_{brand}_{view}_{size}.{ext}
  # The {size} token is normally a t-shirt enum (tn|sm|md|lg|xl|xxl) but the
  # CDN also accepts arbitrary integer widths and clamps to source. Asking for
  # 2000 returns the master (typically 2000x2666) regardless of brand/view.
  if [[ "$url" =~ /images/products/[^/]+/[^/]+_(tn|sm|md|lg|xl|xxl|[0-9]+)\.(jpg|jpeg|webp|png)(\?|$) ]]; then
    echo "$url" | sed -E 's#_(tn|sm|md|lg|xl|xxl|[0-9]+)\.(jpg|jpeg|webp|png)#_2000.\2#'
    return 0
  fi

  return 1
}

# -- Category B: Path-segment CDNs -------------------------------------------

cdn_resolve_cloudinary() {
  local url="$1"
  # Match res.cloudinary.com OR any custom CNAME using the /{cloud}/image/upload/
  # path signature. Custom CNAMEs (images.complex.com, images.gq.com, etc.) are
  # commonplace; the path layout is the reliable identifier.
  [[ "$url" == *"/image/upload/"* ]] || return 1

  local base="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="?${url#*\?}"

  local before="${base%%/image/upload/*}"
  local after="${base#*/image/upload/}"

  # split remaining path into segments, skip transforms
  local result="" skipping=true seg changed=false
  local saved_IFS="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  set -- $after
  IFS="$saved_IFS"

  for seg in "$@"; do
    [[ -z "$seg" ]] && continue
    if $skipping && _is_cloudinary_transform "$seg"; then
      changed=true
      continue
    fi
    skipping=false
    result="${result}/${seg}"
  done

  result="${result#/}"
  [[ -n "$result" ]] || return 1

  # Cloudinary public IDs typically have no extension — the bare URL serves
  # auto-format (compressed JPG). Appending .png both forces the lossless
  # ceiling AND lets path_probe discover .tif/.jpg/.webp variants of the same
  # asset (path_probe only fires on URLs that already have an image extension).
  local lower
  lower="$(printf '%s' "$result" | tr '[:upper:]' '[:lower:]')"
  if ! [[ "$lower" =~ \.(jpg|jpeg|png|tif|tiff|webp|gif|avif|heic)$ ]]; then
    result="${result}.png"
    changed=true
  fi

  # If we didn't strip a transform and didn't add an extension, the URL was a
  # no-op for us — return failure so the dispatcher tries the next resolver.
  $changed || return 1

  echo "${before}/image/upload/${result}${query}"
}

# Cloudinary bare-origin master check (runtime/network — NOT a pure resolver).
# cdn_resolve_cloudinary appends `.png` to extensionless public IDs to force a
# lossless ceiling and enable format negotiation. But that assumes the bare URL
# serves a lossy q_auto default — which is account-dependent, NOT universal. When
# the account does NOT force optimized delivery, the bare (transform-stripped,
# extensionless) URL already serves the STORED ORIGINAL byte-for-byte; if that
# original was uploaded as a JPEG, the `.png` render is merely a lossless re-wrap
# of already-lossy pixels — same dimensions, several times the bytes, ZERO added
# fidelity — yet it wins the format-priority(PNG>JPG)+size ladder and gets picked
# as the "master." (Found 2026-07-01 on cloud `allyou`/gregswales.com: bare = the
# 1.33 MB source JPEG, `.png` = a 6.6 MB re-wrap of the same 2000×2500 pixels.)
#
# Ask Cloudinary's own fl_getinfo for the source byte count (`input.bytes`); if a
# bare-URL HEAD matches it exactly, the bare URL IS the byte-exact original — return
# it so the caller can prefer it and skip the format ladder. Echoes nothing (and
# returns non-zero) when the fix does not apply: not a `.png`-appended Cloudinary
# URL, fl_getinfo unavailable (older accounts / no add-on), or the account optimizes
# the bare delivery (bare bytes < source bytes) — in which case the existing `.png`
# lossless-ceiling behaviour remains the best available fallback and is left intact.
cloudinary_bare_master() {
  local url="$1"
  # Only the resolver's appended-.png case can exhibit the re-wrap bloat. A public
  # ID that already carried an extension (.jpg/.png/…) is served byte-exact bare and
  # was never re-wrapped, so there is nothing to correct. Guard cheaply BEFORE any
  # network call so the offline test harness never touches the wire.
  [[ "$url" == *"/image/upload/"* ]] || return 1
  local base="${url%%\?*}"
  [[ "$base" == *.png ]] || return 1

  local bare="${base%.png}"                       # transform already stripped by resolver
  local before="${bare%%/image/upload/*}"
  local pubid="${bare#*/image/upload/}"

  local info src_bytes bare_info bare_bytes
  info="$(curl -s "${CURL_TIMEOUT_OPTS[@]}" -L "${before}/image/upload/fl_getinfo/${pubid}" 2>/dev/null)" || return 1
  # Isolate the "input":{…} object (the SOURCE asset) and read its byte count —
  # deliberately NOT output.bytes, which is fl_getinfo's own delivery rendition.
  src_bytes="$(printf '%s' "$info" \
    | sed -n 's/.*"input"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
    | grep -oE '"bytes"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
  [[ -n "$src_bytes" && "$src_bytes" -gt 0 ]] || return 1

  # Content-Length of the bare (extensionless) delivery — the candidate master.
  bare_info="$(head_info "$bare")" || return 1
  bare_bytes="$(sed -n '2p' <<< "$bare_info")"
  [[ "$bare_bytes" == "$src_bytes" ]] || return 1  # only trust bare when it is byte-exact

  echo "$bare"
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

# BDG (Bustle Digital Group) serves every title it owns — Nylon, Bustle, Romper,
# Inverse, Mic, W, The Zoe Report, Elite Daily, Scary Mommy, Fatherly, Input —
# through a single imgix source at the CUSTOM domain `imgix.bustle.com`. It is
# NOT a `*.imgix.net` host, so cdn_resolve_imgix never matched it and the URL
# fell through to generic param-stripping (which lands on the LOSSY bare rendition).
#
# Uploads are high-quality camera originals: imgix `fm=json` reports the source of
# a Gracie Abrams cover frame as 7341×9177, 4.0 MB, with full DateTimeOriginal
# EXIF. But imgix delivers a lossy default re-encode even on the BARE URL — bare
# `oshiro_ga_-22` (6449×8062) = 1.87 MB (~q75) while `?q=100` = 6.81 MB at the
# SAME dimensions (3.65× the real data). So, exactly like a high-quality Sanity
# dataset, the bare URL is NOT the master; the best publicly obtainable rendition
# is `?q=100` at native resolution.
#
# imgix hard-caps output at 8192px on the long edge: sources ≤8192 come back at
# full native res under `?q=100`; a source above it (the 7341×9177 frame) is
# downscaled to 6553×8192 and the true original lives only on imgix's private
# origin bucket (imgix strips the upload's EXIF on delivery — the byte-exact
# original is not publicly retrievable). `fm=png`/`fm=tif` would lossless-wrap the
# lossy JPEG source (a bloat/wrapper trap); the existing transcode guard demotes
# it, so no probe-suppression is needed here (unlike SKIMS, whose w= params
# upscale — the page URLs here carry only downscaling w=, harmless to probe).
#
# Strategy: strip all params and append `?q=100`. Placed before cdn_resolve_imgix
# in the dispatcher for clarity (the generic imgix host match can't fire anyway).
cdn_resolve_imgix_bustle() {
  local url="$1"
  [[ "$url" == *"imgix.bustle.com/"* ]] || return 1
  echo "${url%%\?*}?q=100"
}

# SKIMS serves all its media through two imgix sources:
#   - `skims.imgix.net`        — origin is the Shopify file store
#                                (`/s/files/1/0259/5448/4284/files/<name>.<ext>`)
#   - `skims-sanity.imgix.net` — origin is the Sanity CMS asset store
#                                (`/images/<proj>/production/<hash>-<WxH>.<ext>`)
#
# The site only ever requests heavily-shrunk transcodes: `auto=format&q=70&w=1446`
# yields a ~107 KB AVIF off a 2000×2000 upload. Like any imgix source, requesting
# the BARE URL (no query params) returns the origin upload BYTE-FOR-BYTE — verified
# by matching `?fm=json`'s reported source Content-Length to the GET size:
#   bare PANTY_00020…webp  = 150,644 B / 2000×2000 / image/jpeg (the upload master);
#   the Shopify origin (`cdn.shopify.com/s/files/…`) returns the identical 150,644 B.
#
# CRITICAL — the uploads are LOSSY JPEGs (Shopify stores them with a `.webp`
# extension but the bytes are JPEG, confirmed by magic bytes + `fm=json`
# Content-Type). So unlike StockX (whose source is a lossless Photoshop PNG and
# where `?fm=png` recovers the true master), on SKIMS the format ladder is a
# pure-bloat TRAP:
#   bare           = 150,644 B  image/jpeg   ← honest master
#   ?fm=png        = 922,256 B  image/png    ← lossless wrapper of the lossy JPEG
#   ?fm=tif        = 163,601 B  image/tiff   ← TIFF-wrapped JPEG (TOP format priority)
# Both re-encodes are pixel-identical to the JPEG (zero added fidelity) yet would
# beat it on format priority (TIF) or the 4× size-dominance override (PNG). The
# bare source is therefore the only correct answer, and `param_probe`/`path_probe`
# must be suppressed for these hosts (see is_skims_imgix_url usage below).
#
# imgix clamps to source (no upscaling: `?w=4000` still reports 2000×2000), and the
# Shopify origin clamps too (`?width=4000` → 150,644 B), so 2000×2000 is the ceiling.
# Placed before cdn_resolve_imgix so it claims SKIMS hosts (the generic stripper
# would produce the same bare URL, but matching here documents the lossy-source
# trap and lets the probe stages key off is_skims_imgix_url).
is_skims_imgix_url() {
  local url="$1"
  [[ "$url" == *"skims.imgix.net/"* ]] || [[ "$url" == *"skims-sanity.imgix.net/"* ]]
}

cdn_resolve_skims() {
  local url="$1"
  is_skims_imgix_url "$url" || return 1
  local result="${url%%\?*}"
  [[ "$result" == "$url" ]] && return 1
  echo "$result"
}

# StockX product images are served from `images.stockx.com`, an imgix-backed
# CDN with a heavily restricted custom config: `w=`/`q=`/`fm=` are silently
# ignored, and only `?dpr=N` survives. Even with dpr=4 the public host caps
# at an UPSCALED 2400×1712 / 441 KB JPEG that re-encodes the upload.
#
# The unrestricted root imgix subdomain `stockx.imgix.net` shares the same
# S3 source bucket and exposes the full imgix API. Crucially, requesting
# the BARE URL (no query params) on stockx.imgix.net returns the source
# upload BYTE-FOR-BYTE — verified by matching `?fm=json`'s reported
# Content-Length to the GET response size:
#   - hero (Yeezy cleat) — bare = 1,231,532 B / 1600×1141 (Adobe Photoshop
#     master); `images.stockx.com?dpr=4` = 441,404 B / 2400×1712 (1.5× upscale
#     + JPEG re-encode, fewer real pixels at higher fake resolution)
#   - 360 turntable frame img01 — bare = 948,710 B / 2000×1500 (true source);
#     `images.stockx.com?dpr=4` = 399,742 B / 2400×1800 (upscaled re-encode)
#
# Strategy: rewrite the host to `stockx.imgix.net` and drop ALL query params
# to get the byte-exact source. Inputs already on `stockx.imgix.net` get
# their params stripped. The secondary CMS imgix host `stockx-assets.imgix.net`
# is a separate imgix source (payment icons etc., not product photos) and
# is left to the generic cdn_resolve_imgix.
#
# Goes in the dispatcher BEFORE cdn_resolve_imgix so stockx.imgix.net hits
# this resolver first (otherwise the generic imgix stripper would handle it
# and produce the same canonical bare URL — same outcome, but explicit
# matching here makes the intent obvious and lets us evolve independently).
cdn_resolve_stockx() {
  local url="$1"
  local path result

  if [[ "$url" == *"images.stockx.com/"* ]]; then
    path="${url#*images.stockx.com/}"
    path="${path%%\?*}"
    result="https://stockx.imgix.net/${path}"
  elif [[ "$url" == *"stockx.imgix.net/"* ]]; then
    result="${url%%\?*}"
  else
    return 1
  fi

  # No-op guard: if the rewrite produced the input unchanged, signal failure
  # so the dispatcher can try other resolvers / fall through.
  [[ "$result" == "$url" ]] && return 1
  echo "$result"
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

# Empirically derived from /Users/salvatore/downloads/cdn/shopify_learnings.md:
#   - The bare URL is a re-encoded JPEG at q≈75 (Shopify's imagery pipeline).
#   - ?format=png is a lossless container, raw-RGB-pixel-identical to ?quality=100
#     and ?format=bmp (verified via PIL+md5).
#   - ?format=tiff/tif/avif/heic silently fall back to JPEG with image/jpeg
#     content-type — DO NOT use these (handled by path_probe/param_probe guards).
#   - Source dimensions are a hard ceiling. ?width=N, ?dpr=N, _NxN clamp ≤ source.
#   - Two URL forms serve the same asset:
#       cdn.shopify.com/s/files/<store-id>/(products|files)/<filename>      (canonical)
#       <storefront-domain>/cdn/shop/(products|files)/<filename>            (proxy via storefront)
#   - Store-id depth is variable: learnings doc test asset = 3 segments
#     (1/0094/2252); parisaint = 4 segments (1/0231/9148/6542). Use \d+/+
#   - Cache-buster ?v=<ts> is harmless and must be preserved.
#
# Recipe:
#   1. Strip size suffix (filename _NxN, _grande, etc.) — NOT _master/_original
#      (those are higher-fidelity renditions when present; the legacy resolver
#      stripped them, which is wrong per the learnings doc).
#   2. Drop transform params (?width, ?dpr, ?crop, ?height, ?quality), keep ?v=.
#   3. Append ?format=png (with &v=<ts> if present).
#
# _master probing: NOT done here. The doc recommends probing per-asset, but for
# parisaint.com the storefront-served images don't carry _master at all — and
# the same source pixels are recovered by ?format=png on the bare URL. Phase 5c
# verifies this empirically before committing to skip the probe shop-wide.
cdn_resolve_shopify() {
  local url="$1"
  # Detect both URL forms.
  if ! [[ "$url" =~ cdn\.shopify\.com/s/files/[0-9]+/ ]] \
     && ! [[ "$url" == *"/cdn/shop/products/"* ]] \
     && ! [[ "$url" == *"/cdn/shop/files/"* ]]; then
    return 1
  fi

  local base="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="${url#*\?}"

  # 1. Strip size suffix from filename only (last path segment).
  base="$(echo "$base" | sed -E '
    s/_(pico|icon|thumb|small|compact|medium|large|grande)(\.[A-Za-z0-9]+)$/\2/;
    s/_[0-9]+x[0-9]+(\.[A-Za-z0-9]+)$/\1/
  ')"

  # 2. Keep only ?v= from existing query string (drop width/dpr/crop/quality/etc.)
  local v_param=""
  if [[ -n "$query" ]]; then
    v_param="$(printf '%s' "$query" | tr '&' '\n' | grep -E '^v=' | head -1 || true)"
  fi

  # 3. Append ?format=png (lossless container — peak fidelity rendition).
  local result
  if [[ -n "$v_param" ]]; then
    result="${base}?${v_param}&format=png"
  else
    result="${base}?format=png"
  fi

  [[ "$result" != "$url" ]] || return 1
  echo "$result"
}

# Helper used by path_probe/param_probe to skip Shopify-trap format swaps.
is_shopify_image_url() {
  local url="$1"
  [[ "$url" == *"cdn.shopify.com/s/files/"* ]] \
    || [[ "$url" == *"/cdn/shop/products/"* ]] \
    || [[ "$url" == *"/cdn/shop/files/"* ]]
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
  # Hypebeast CDN (CloudFront + Lambda): two distinct upstream backends.
  #
  # 1) HBX commerce flow — origin `s3.store.hypebeast.com/media/image/...`:
  #    the S3 bucket is publicly readable, the proxy is a downstream re-encode
  #    that strips EXIF/TIFF metadata. Direct S3 URL is the master and bypasses
  #    both the proxy AND the AWS WAF that fronts hbx.com PDPs. Path is
  #    /image-cdn.hypb.st/{url-encoded http(s)://s3.store.hypebeast.com/...}.
  #
  # 2) Editorial flow — origin `hypebeast.com/image/...`:
  #    the proxy IS the storage authority (no public S3). Backend caps width
  #    at 1200 regardless of requested w; q=100 (vs site's 90) ~doubles bytes
  #    with measurable fidelity gain.
  local base="${url%%\?*}"
  local encoded="${base#*image-cdn.hypb.st/}"

  # Commerce: decode the proxied origin URL and use it directly
  if [[ "$encoded" == *"s3.store.hypebeast.com"* || "$encoded" == *"s3%2Estore%2Ehypebeast%2Ecom"* ]]; then
    local decoded
    decoded="$(printf '%b' "${encoded//%/\\x}" 2>/dev/null)" || decoded=""
    if [[ -n "$decoded" && "$decoded" == http*"s3.store.hypebeast.com/media/image/"* ]]; then
      echo "$decoded"
      return 0
    fi
  fi

  # Editorial: stay on the proxy, request native resolution + max quality
  echo "${base}?q=100&w=9999"
}

cdn_resolve_arc_resizer() {
  local url="$1"
  # Arc Publishing / Arc XP resizer (WaPo, Tampa Bay Times, Business of Fashion,
  # hundreds of US news orgs — detect site via arc-perso.aws.arc.pub in assets).
  # URL pattern: /resizer/v2/HASH.ext?auth=TOKEN[&width=X&height=Y&smart=true]
  # The auth HMAC signs ONLY the image path/HASH, so width/height/smart are free
  # params — and imbypass=true overrides ALL of them, bypassing the resizer to
  # return the untouched original upload with full EXIF/IPTC and no re-encoding.
  # Verified on tampabay.com: a thumbnail URL carrying &width=160&height=90 plus
  # &imbypass=true returns the byte-exact 6016x4016 master (md5-identical to the
  # CloudFront origin cloudfront-us-east-1.images.arcpublishing.com/<org>/<HASH>.ext).
  # The page's default resizer output (no dims) is a same-pixels lossy re-encode
  # ~21% smaller with EXIF stripped — the "looks full-res but isn't" trap.
  # (The CloudFront origin needs no auth and never expires, but the <org> slug
  # isn't present in the resizer path, so it can't be derived here — imbypass it.)
  [[ "$url" == */resizer/* ]] || return 1
  [[ "$url" == *"auth="* ]] || return 1
  append_param "$url" "imbypass" "true"
}

# Squarespace image CDN. Two host patterns:
#   images.squarespace-cdn.com/content/v1/{site}/{img}/{filename}
#   static1.squarespace.com/static/{site}/{page}/{img}/{ts}/{filename}
# Three quirks make this CDN especially hostile:
#   1. Bare URL (no ?format=) returns a 1-byte sentinel (Content-Length: 1)
#   2. ?format=NNNw caps at the upload max (often 2500w); ?format=original
#      returns the uploaded source file
#   3. File format is determined ENTIRELY by the Accept request header,
#      not by ?format= or the URL path. Accept: */* or any header
#      containing "webp" → server returns WebP; otherwise → original format.
#      So aria2c's default Accept: */* silently downloads a WebP transcode
#      even when probing reports a much larger JPEG/PNG original.
# is_squarespace() and the SQUARESPACE_ACCEPT header coordinate the fix
# in head_info() and the download path.
SQUARESPACE_ACCEPT="image/avif,image/png,image/jpeg,image/tiff,image/bmp"

is_squarespace() {
  [[ "$1" == *"images.squarespace-cdn.com/"* ]] && return 0
  [[ "$1" == *".squarespace-cdn.com/"* ]] && return 0
  [[ "$1" == *"static1.squarespace.com/"* ]] && return 0
  return 1
}

# Penske Media Corp (PMC) titles run on WordPress VIP fronted by Jetpack Photon.
# Images live on-domain at <host>/wp-content/uploads/<YYYY>/<MM>/<name>.<ext>.
# Photon transcodes to a LOSSY webp at the SAME pixel dimensions (EXIF stripped,
# ~30% smaller) whenever the request's Accept header contains webp — exactly the
# Squarespace quirk #3 — so the page paints a webp even though the bare upload is
# an untouched JPEG/PNG master with full EXIF. The fix is identical: send a
# no-webp Accept (reuse SQUARESPACE_ACCEPT) so Photon serves the original format.
# Adding ANY query param (?w=/?quality=/?strip=/?crop=) also re-invokes Photon and
# shrinks/strips the file, so the master is the BARE upload URL — see
# cdn_resolve_pmc(), which strips Photon params. Host list = the confirmed PMC
# WordPress-VIP+Photon properties (extend as new ones are verified).
is_pmc_photon() {
  case "$1" in
    *://www.rollingstone.com/wp-content/uploads/*) return 0 ;;
    *://variety.com/wp-content/uploads/*)          return 0 ;;
    *://wwd.com/wp-content/uploads/*)              return 0 ;;
    *://www.indiewire.com/wp-content/uploads/*)    return 0 ;;
    *://www.sheknows.com/wp-content/uploads/*)     return 0 ;;
  esac
  return 1
}

# Sites whose Photon/transcode backend must be coaxed with a no-webp Accept so
# the original-format master is served instead of a lossy webp derivative.
wants_original_accept() {
  is_squarespace "$1" || is_pmc_photon "$1"
}

# Akamai Image Manager bypass shared by NBC / FWRD / Revolve. Their origins are
# all fronted by Akamai Image Manager, which silently transcodes/re-compresses
# the source on bare requests. The named policy ?impolicy=original bypasses ALL
# transformations and returns the untouched upload. Strips any existing query
# first, then appends the policy. Defined once so the magic string lives in one
# place. (Callers do their own host/path matching before calling this.)
_akamai_impolicy() {
  local base="${1%%\?*}"
  echo "${base}?impolicy=original"
}

cdn_resolve_nbc() {
  local url="$1"
  # NBC's image host is fronted by Akamai Image Manager. Bare requests for
  # /files/<date>/<slug>.png return a JPEG transcode (Content-Type silently
  # rewritten to image/jpeg) at downscaled quality. The reliable bypass is
  # ?impolicy=original — a named policy NBC has configured to return the
  # untouched source upload (verified ~1.78 MB PNG at 1920x1080 vs 285 KB
  # JPEG bare; sometimes 2-3 MB).
  #
  # ?imformat=png is NOT a reliable substitute: it works for some assets
  # (e.g. nikkiglaser_03_090) but is silently ignored for others (e.g.
  # bad_bunny_01_017, sombr_01_142) — Akamai still serves JPEG even though
  # the URL contains imformat=png. The asymmetry depends on per-asset
  # policy configuration we can't see from outside; ?impolicy=original is
  # universally honoured because it bypasses ALL transformations.
  [[ "$url" == *"://img.nbc.com/"* ]] || return 1
  _akamai_impolicy "$url"
}

cdn_resolve_fwrd() {
  local url="$1"
  # FWRD's image host (is1-is8.fwrdassets.com) is Akamai Image Manager fronting
  # an nginx/1.20.1 origin. Bare /images/p/fw/{p|uv|z}/<sku>_V<n>.jpg is served
  # re-compressed (38.5 dB PSNR vs origin); ?impolicy=original bypasses Image
  # Manager and returns the unmodified source upload (2.2-2.9x larger, Exif
  # header intact, last-modified = original upload date). Verified across
  # YEEZY Season 3 SKU YEF3-WK1: V1-V6 all gain 2.18-2.86x in size.
  #
  # ?cb=<anything> also bypasses on cache miss (hits Akamai Image Server proxy)
  # but returns the bare-quality file once warm — unreliable. ?impolicy=original
  # is the universal bypass and matches the NBC pattern. Match is strictly
  # scoped to /images/p/fw/{p|uv|z}/<sku>_V<n>.<ext> to exclude fonts, CSS, and
  # favicons under other paths on the same host.
  [[ "$url" =~ ^https?://is[0-9]+\.fwrdassets\.com/images/p/fw/(p|uv|z)/.+_V[0-9]+\.(jpg|jpeg|png|JPG|JPEG|PNG)(\?|$) ]] || return 1
  _akamai_impolicy "$url"
}

cdn_resolve_revolve() {
  local url="$1"
  # Revolve is FWRD's sister site (RVLV-owned, same Akamai-Image-Manager →
  # nginx/1.20.1 origin pattern). Image host: is[1-8].revolveassets.com.
  # Folder hierarchy: /images/p4/n/{c|ct|d|dt|ps|z}/<basename>_V<n>.jpg —
  # /z/ is the largest tier (verified ~94 KB bare → ~220 KB with bypass on
  # YEER-UO4W_V1; same 1.9-2.5x ratio observed across other YEEZY products).
  # Same ?impolicy=original Akamai named-policy bypass as FWRD/NBC.
  #
  # NOTE: Revolve image filenames sometimes include a per-color-variant
  # single-letter suffix (e.g. SKU YEER-UO4 stores images as YEER-UO4W_V1.jpg)
  # — the regex tolerates that since we match on the full filename token.
  [[ "$url" =~ ^https?://is[0-9]+\.revolveassets\.com/images/p4/n/(c|ct|d|dt|ps|z)/.+_V[0-9]+\.(jpg|jpeg|png|JPG|JPEG|PNG)(\?|$) ]] || return 1
  # Normalize folder to /z/ (largest tier) regardless of which folder the
  # caller passed in, then append the bypass.
  local base
  base="$(echo "$url" | sed -E 's#/images/p4/n/(c|ct|d|dt|ps|z)/#/images/p4/n/z/#')"
  _akamai_impolicy "$base"
}

cdn_resolve_rebelmouse() {
  local url="$1"
  # RebelMouse CMS proxy: <tenant>.com/media-library/<basename>.<ext>?id=<N>&...
  # is a re-encoder in front of S3 bucket assets.rbl.ms.  Each numeric id maps
  # to exactly one file: assets.rbl.ms/<id>/origin.<ext> where <ext> mirrors
  # the original upload format (verified across paper, indy100, okayplayer-
  # style tenants — the publisher's templating reads the upload's extension
  # into the proxy URL, so /image.png?id=N indicates a PNG upload and
  # /image.jpg?id=N indicates a JPEG upload).
  #
  # The proxy's &quality=100 knob is a server-side re-encode: it produces a
  # ~3x larger file than the S3 origin while remaining pixel-equivalent
  # (PSNR 56 dB) — adds zero information beyond the source upload.  The bare
  # S3 origin is the true ceiling and the only honest "lossless" answer.
  #
  # Multi-tenant: same path layout is used by every RebelMouse-hosted
  # publication, so we match on the URL path, not the hostname.  If our
  # extension guess is wrong, the dispatcher's tail-end head_info validator
  # rejects the 404 and falls back to the original URL; downstream
  # path_probe will then swap extensions to discover the true upload format.
  [[ "$url" =~ /media-library/[^/?]+\.(jpe?g|png|gif|webp|tiff?)\?(.*&)?id=([0-9]+)([&#]|$) ]] || return 1
  local ext="${BASH_REMATCH[1]}"
  local id="${BASH_REMATCH[3]}"
  echo "https://assets.rbl.ms/${id}/origin.${ext}"
}

cdn_resolve_squarespace() {
  local url="$1"
  is_squarespace "$url" || return 1

  # Strip any existing format= / content-type= params (and ?format=raw, which
  # silently returns a 100w thumbnail), then re-append ?format=original.
  local base="${url%%\?*}"
  local query=""
  [[ "$url" == *"?"* ]] && query="${url#*\?}"

  if [[ -n "$query" ]]; then
    # remove format= and content-type= keys, keep everything else
    local cleaned=""
    local IFS='&'
    local pair
    for pair in $query; do
      case "$pair" in
        format=*|content-type=*) ;;
        *) cleaned="${cleaned:+${cleaned}&}${pair}" ;;
      esac
    done
    if [[ -n "$cleaned" ]]; then
      echo "${base}?${cleaned}&format=original"
    else
      echo "${base}?format=original"
    fi
  else
    echo "${base}?format=original"
  fi
}

# -- GOAT (image.goat.com) ----------------------------------------------------
#
# GOAT serves product photos via Active-Storage-style paths. Three layers can
# all degrade fidelity below the source upload:
#   1. /transform/v1/<path>?action=crop&width=N — crops to a fixed aspect
#      ratio, capping width below source. e.g. 981480_02 source is 3000x2000
#      but ?action=crop&width=10000 returns 2764x1865 (lossy crop).
#   2. /<N>/<path> — clamps the longest side to N pixels (no upscaling, but
#      a force-resize if N < source).
#   3. /<sub-size>/ folder in the path — original > large > medium > grid.
#
# The bare URL (no transform prefix, no width prefix, /original/ sub-size)
# always serves the unmodified source upload. Source dimensions vary by
# asset: some are 2000x1333, some are 3000x2000.
#
# Confirmed from a HAR capture of www.goat.com/sneakers/* — the website
# itself uses ?action=crop&width=750..2600, never the bare URL.
cdn_resolve_goat() {
  local url="$1"
  [[ "$url" == *"image.goat.com/"* ]] || return 1

  local base="${url%%\?*}"

  # Strip optional /transform/v1/ prefix
  base="${base/\/transform\/v1\///}"

  # Strip optional width prefix (/375/, /750/, /1000/, /99999/, etc.) and
  # optional named prefix variants like /glow-4-5-25/750/.
  # Anchor to the host so we only touch the prefix slot, not interior path
  # segments that could legitimately contain digits.
  if [[ "$base" =~ ^(https?://image\.goat\.com)/([a-z0-9-]+/)?([0-9]+/)?(attachments/.*)$ ]]; then
    base="${BASH_REMATCH[1]}/${BASH_REMATCH[4]}"
  else
    return 1
  fi

  # Promote sub-size folder to /original/ when present (grid|medium|large).
  if [[ "$base" =~ ^(.*)/(grid|medium|large)/([^/]+)$ ]]; then
    base="${BASH_REMATCH[1]}/original/${BASH_REMATCH[3]}"
  fi

  # No-op guard: if rewrite produced an identical URL with no query change,
  # let later resolvers / the dispatcher try other angles.
  if [[ "$base" == "$url" ]]; then
    return 1
  fi

  echo "$base"
}

# -- iTunes / Apple Music artwork (mzstatic.com) ------------------------------
#
# Apple serves all artwork (album covers, artist images, podcast art, etc.)
# through two hosts:
#
#   1. is{N}-ssl.mzstatic.com/image/thumb/<PATH>/<SPEC>  — the PUBLIC resizer.
#      <SPEC> is {w}x{h}[crop][-quality].{fmt}, e.g. 600x600bb.jpg or the
#      caller's 10000x0w-999.png.  The resizer CLAMPS to the source resolution
#      (no upscaling) and, when {fmt}=png, re-encodes losslessly.  So requesting
#      an oversized PNG returns the full-resolution source as lossless PNG.
#      Verified ceiling: 10000 is accepted, 20000 → HTTP 400 — therefore
#      10000x10000.png is the max-safe lossless spec.  A 2003x2003
#      AMCArtistImages source came back byte-for-byte identical (9 639 083 B)
#      whether requested as 10000x10000, 10000x0w, or 10000x10000bb — the fit
#      modes converge once clamped to source, so the bare 10000x10000 (no crop
#      code, which never pads) is the simplest correct spec.
#
#   2. a{N}.mzstatic.com/<cc>/r{N}/<part>/<PATH>/<file>  — the LEGACY origin.
#      Hard-403s every public request, including with a browser User-Agent
#      (only Apple's own clients carry the required token).  <file> is either
#      the real upload name (ami-identity-*.png, etc.) or the bare alias
#      "source".
#
# Strategy: route everything onto the resizer host with a 10000x10000.png spec.
#   - thumb URL: swap whatever <SPEC> the caller passed for 10000x10000.png.
#   - legacy a{N} URL with a REAL filename: strip the <cc>/r{N}/<part>/ prefix
#     (the remaining <PATH>/<file> is exactly the resizer's path key) and append
#     the spec.  Verified: the 403'd named-PNG legacy URL resolves to a 200 on
#     the resizer this way.
#   - legacy a{N} URL ending in the bare "source" alias: NOT recoverable — the
#     resizer has no "source" key (verified 404), and the real filename can't be
#     derived from the URL alone.  Left unresolved (returns 1); the baseline
#     probe will then fail on the 403 origin.  Feed the named or thumb form
#     instead when you have it.
cdn_resolve_mzstatic() {
  local url="$1"

  # Form 1: is{N}[-ssl].mzstatic.com/image/thumb/<PATH>/<SPEC>
  if [[ "$url" =~ ^https?://is[0-9]+(-ssl)?\.mzstatic\.com/image/thumb/(.+)/[0-9]+x[0-9]+[a-z]*(-[0-9]+)?\.(jpe?g|png|tiff?|webp|bmp)([?#].*)?$ ]]; then
    echo "https://is1-ssl.mzstatic.com/image/thumb/${BASH_REMATCH[2]}/10000x10000.png"
    return 0
  fi

  # Form 2: legacy a{N}.mzstatic.com/<cc>/r{N}/<part>/<PATH>/<file.ext>
  # Require a real image-file extension as the last path segment — the bare
  # "source" alias has no extension here and is intentionally skipped.
  if [[ "$url" =~ ^https?://a[0-9]+\.mzstatic\.com/[a-z]{2}/r[0-9]+/[0-9]+/(.+\.(jpe?g|png|tiff?|webp|bmp))([?#].*)?$ ]]; then
    echo "https://is1-ssl.mzstatic.com/image/thumb/${BASH_REMATCH[1]}/10000x10000.png"
    return 0
  fi

  return 1
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
  done < <(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$base" -H "User-Agent: $ua" \
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
    raw_urls="$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" "$page" -H "User-Agent: $ua" \
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

  # Each CDN-specific resolver is tried in priority order; the first that
  # returns a non-empty rewrite wins. Order matters — more-specific resolvers
  # precede generic host matches.
  #
  # cdn_resolve_shopify_legacy is INTENTIONALLY omitted: it strips
  # _master/_original (higher-fidelity renditions per shopify_learnings.md);
  # the Category A cdn_resolve_shopify handles size-suffix stripping correctly.
  local resolvers=(
    # Category E: proxy CDNs (extract original URL)
    cdn_resolve_substack cdn_resolve_playboy
    cdn_resolve_nextjs cdn_resolve_netlify cdn_resolve_wp_photon
    cdn_resolve_pmc cdn_resolve_wp_uploads cdn_resolve_cloudflare_images cdn_resolve_thumbor
    cdn_resolve_format
    # Category D: proprietary path CDNs
    cdn_resolve_wsj cdn_resolve_condenast cdn_resolve_google cdn_resolve_twitter
    cdn_resolve_pinterest cdn_resolve_reddit_preview cdn_resolve_discogs cdn_resolve_hdnux cdn_resolve_futurecdn cdn_resolve_ynap cdn_resolve_arc_resizer cdn_resolve_goat
    cdn_resolve_nbc cdn_resolve_fwrd cdn_resolve_revolve cdn_resolve_rebelmouse
    cdn_resolve_mzstatic
    # Category B: path-segment CDNs
    cdn_resolve_cloudinary cdn_resolve_uploadcare cdn_resolve_storyblok
    cdn_resolve_tumblr cdn_resolve_cargo
    # Category C: filename-suffix CDNs
    cdn_resolve_imgur cdn_resolve_flickr cdn_resolve_cargocollective
    # Category A: query-param CDNs
    cdn_resolve_skims cdn_resolve_stockx cdn_resolve_imgix_bustle cdn_resolve_imgix cdn_resolve_sanity cdn_resolve_contentful
    cdn_resolve_shopify cdn_resolve_akamai cdn_resolve_fastly cdn_resolve_bunny
    cdn_resolve_sirv cdn_resolve_hypbst cdn_resolve_squarespace
  )
  local fn
  for fn in "${resolvers[@]}"; do
    [[ -n "$resolved" ]] && break
    resolved="$("$fn" "$url" 2>/dev/null)" || true
  done

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

  # Validate resolved URL via head_info (which already retries GET when HEAD
  # returns a known false-negative pattern — Cargo 403, Hypebeast CL=0, GOAT
  # cold-cache 4xx-with-tiny-body). A bare http_status() check would HEAD-only
  # and miss the GOAT trap, falsely rejecting a perfectly good resolved URL.
  if [[ -n "$resolved" && "$resolved" != "$url" ]]; then
    local val_info val_ct val_cl
    val_info="$(head_info "$resolved")"
    val_ct="$(sed -n '1p' <<< "$val_info")"
    val_cl="$(sed -n '2p' <<< "$val_info")"
    # Accept image/* OR (binary/octet-stream + image extension on URL).  The
    # second case is imgix passthrough behaviour: when no transform params
    # are present, imgix returns the source bytes verbatim and reports
    # `Content-Type: binary/octet-stream` because it doesn't run magic-byte
    # detection on bare requests. stockx.imgix.net does this for product
    # images (verified — the bare URL returns the byte-exact 1.23 MB Adobe
    # Photoshop master JPEG with binary/octet-stream Content-Type).
    local is_image_ct=false
    [[ "$val_ct" == image/* ]] && is_image_ct=true
    if [[ "$val_ct" == "binary/octet-stream" ]] && \
       [[ "${resolved%%\?*}" =~ \.(jpe?g|png|gif|webp|tiff?|bmp|avif|heic)$ ]]; then
      is_image_ct=true
    fi
    if $is_image_ct && (( ${val_cl:-0} > 1024 )); then
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
      if [[ "$l_fmt" != "png-indexed" && "$l_fmt" != "png-grayscale" && "$l_fmt" != *-transcode ]]; then
        best="$largest"
      fi
    fi
  fi

  echo "$best"
}

# Rebuild CANDIDATES, swapping the entry equal to the current $winner for $1.
# Used by stage_select_winner to demote/correct a convicted winner in place so
# the next select_best() pass picks a different candidate.
replace_winner_candidate() {
  local repl="$1" c new=()
  for c in "${CANDIDATES[@]}"; do
    if [[ "$c" == "$winner" ]]; then new+=("$repl"); else new+=("$c"); fi
  done
  CANDIDATES=("${new[@]}")
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

  # Shopify trap (per shopify_learnings.md): ?format=tiff/tif/avif/heic silently
  # return JPEG with image/jpeg content-type. add_candidate would record them as
  # "jpg" (correctly), but issuing 12 wasted HEAD requests per image hurts. The
  # cdn_resolve_shopify already produced ?format=png — that's the peak rendition
  # and additional probing won't beat it.
  local is_shopify=false
  is_shopify_image_url "$url" && is_shopify=true

  # SKIMS imgix trap (see cdn_resolve_skims): the bare URL already IS the lossy
  # source upload; every ?fm= re-encode (png/tif) is a pixel-identical lossless
  # wrapper that only bloats bytes and would wrongly win on format priority /
  # size-dominance. No honest format upgrade exists — skip the ladder entirely.
  if is_skims_imgix_url "$url"; then
    return 0
  fi

  for param in "${PARAM_PATTERNS[@]}"; do
    local found_working=false

    for fm in "${PROBE_FMTS[@]}"; do
      # Skip trap formats on Shopify URLs.
      if $is_shopify && [[ "$fm" == "tif" || "$fm" == "tiff" || "$fm" == "avif" || "$fm" == "heic" ]]; then
        continue
      fi
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

  # Cloudinary trap: their f_tiff/.tif endpoint produces a JPEG-compressed TIFF
  # (a TIFF wrapper around lossy JPEG), which is objectively LOWER fidelity than
  # the f_png and even the bare q_auto JPG (verified PSNR: PNG↔TIF=38dB while
  # PNG↔JPG=68dB on a known asset). The format priority ladder treats TIF as
  # highest and would select this trap. Skip TIF for Cloudinary URLs.
  local is_cloudinary=false
  [[ "$base_url" == *"/image/upload/"* ]] && is_cloudinary=true

  # Shopify trap: extension swaps (.jpg → .tif/.png) on Shopify CDN URLs always
  # 404 — the filename is content-addressed and renames don't exist. The format
  # query param (?format=png) is the only valid escape. Skip path_probe entirely
  # for Shopify URLs — saves 5 wasteful HEAD requests per image.
  local is_shopify=false
  is_shopify_image_url "$base_url" && is_shopify=true
  if $is_shopify; then
    return 0
  fi

  # SKIMS imgix: extension swaps (.webp → .png/.tif) hit imgix's origin file path,
  # which has no such sibling (the upload is a single content-addressed file), so
  # every swap 404s. The bare source from cdn_resolve_skims is already the master.
  if is_skims_imgix_url "$base_url"; then
    return 0
  fi

  for ext in "${PATH_EXTS[@]}"; do
    if $is_cloudinary && [[ "$ext" == "tif" || "$ext" == "tiff" ]]; then
      continue
    fi
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
  if aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" -c -x 16 -s 16 -k 1M -o "$(basename "$out")" -d "$OUTDIR" "$prog_url" --quiet; then
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
        vwarn "API unavailable for $vimeo_id$(vimeo_api_unavailable_why) — trying player config path"
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

  local dl_url ref_args=() manifest_info="" had_referer=false

  # A domain-restricted embed only yields a manifest when the embedding page's
  # URL is sent as Referer. That request also fails INTERMITTENTLY (Vimeo hands
  # back an empty/errored player config now and then), so retry once before
  # concluding anything — a single transient miss used to be reported as a hard
  # "embed-only" verdict even though the referer was supplied and correct,
  # sending the user off to dig a progressive URL out of devtools by hand.
  if [[ -n "$referer" && "$referer" != "$url" && "$referer" != *"vimeo.com"* ]]; then
    had_referer=true
    dl_url="https://player.vimeo.com/video/${vimeo_id}"
    ref_args=(--referer "$referer")
    local attempt
    for attempt in 1 2; do
      manifest_info="$(yt-dlp --list-formats "${ref_args[@]}" "$dl_url" 2>/dev/null)" || true
      echo "$manifest_info" | grep -qE '[0-9]+x[0-9]+' && break
      manifest_info=""
      (( attempt == 1 )) && sleep 2
    done
  fi

  if [[ -z "$manifest_info" ]]; then
    dl_url="https://vimeo.com/${vimeo_id}"
    ref_args=()
    manifest_info="$(yt-dlp --list-formats "$dl_url" 2>/dev/null)" || true
  fi

  if [[ -z "$manifest_info" ]] || ! echo "$manifest_info" | grep -qE '[0-9]+x[0-9]+'; then
    if $had_referer; then
      echo "   !! no renditions for ${vimeo_id} even with Referer: ${referer}" >&2
      echo "   (the embed may be private/password-gated, or Vimeo is throttling —" >&2
      echo "    retry, or use --vimeo -c cookies.txt for the authenticated path)" >&2
    else
      echo "   !! embed-only video — needs the URL of the page that embeds it" >&2
      echo "   usage: bash app.sh 'https://example.com/page-with-video'" >&2
      echo "   (the page must server-render the Vimeo embed, not load it via JS)" >&2
    fi
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
  # Vimeo throttles request bursts: the player-config fetch intermittently
  # 401s even with a valid Referer — observed on bodeyco.com seconds after
  # --list-formats had succeeded with the identical arguments. Retry the whole
  # invocation so a throttle isn't reported as a download failure.
  local dl_attempt
  for dl_attempt in 1 2 3; do
    if yt-dlp \
        -f "bestvideo+bestaudio/best" \
        --merge-output-format mp4 \
        --retries 10 \
        --extractor-retries 5 \
        ${ref_args[@]+"${ref_args[@]}"} \
        -o "$out" \
        --no-overwrites \
        "$dl_url" 2>&1 | sed 's/^/   /'; then
      return 0
    fi
    if (( dl_attempt < 3 )); then
      echo "   retrying in 5s (attempt $((dl_attempt + 1))/3)…"
      sleep 5
    fi
  done
  return 2
}

# ── YouTube handler ─────────────────────────────────────────────────────────
# Direct YouTube URLs and page-embedded players. Squarespace (and other
# Embedly-based CMSs) never emit a plain <iframe src="youtube.com/embed/…">:
# the iframe HTML is stored HTML-escaped inside a data-block-json attribute,
# wrapped in an Embedly widget URL, so the video id only appears URL-encoded.
# The page scraper hands ids over as the synthetic form youtube:<id>.
# yt-dlp-only: YouTube's best renditions are adaptive DASH (VP9/AV1 + opus) —
# there is no progressive fallback worth having, so without yt-dlp this
# reports and bails.
# Returns: 0 = handled OK, 1 = not a YouTube URL, 2 = download failed.
handle_youtube() {
  local url="$1" stem="$2"
  local yt_id=""

  if [[ "$url" =~ ^youtube:([A-Za-z0-9_-]{11})$ ]]; then
    yt_id="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ youtu\.be/([A-Za-z0-9_-]{11}) ]]; then
    yt_id="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ youtube(-nocookie)?\.com/(embed|shorts|live|v)/([A-Za-z0-9_-]{11}) ]]; then
    yt_id="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ youtube\.com/watch\?[^[:space:]]*v=([A-Za-z0-9_-]{11}) ]]; then
    yt_id="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  # fix generic stems
  case "$stem" in
    watch|embed|video|"$yt_id") stem="youtube_${yt_id}" ;;
  esac

  # Skip if already downloaded (>1 MB): the merge container depends on the
  # winning codecs (h264+aac → mp4; VP9/AV1+opus → mkv/webm), so check all.
  local ext existing local_size
  for ext in mp4 mkv webm; do
    existing="${OUTDIR}/${stem}.${ext}"
    if [[ -f "$existing" ]]; then
      local_size="$(stat -f%z "$existing" 2>/dev/null || stat -c%s "$existing" 2>/dev/null || echo 0)"
      if (( local_size > 1048576 )); then
        echo "   SKIP (already exists, $(( local_size / 1024 / 1024 )) MB): $existing"
        return 0
      fi
    fi
  done

  if ! has_ytdlp; then
    echo "   YouTube detected but yt-dlp not found — cannot download" >&2
    return 2
  fi

  local watch_url="https://www.youtube.com/watch?v=${yt_id}"
  echo "   YouTube ${yt_id} — fetching renditions..."

  local manifest_info best_res
  manifest_info="$(yt-dlp --list-formats "$watch_url" 2>/dev/null)" || true
  if [[ -n "$manifest_info" ]]; then
    best_res="$(echo "$manifest_info" | grep -oE '[0-9]+x[0-9]+' | tail -1)" || true
    [[ -n "$best_res" ]] && echo "   best → ${best_res}"
  fi

  # No --merge-output-format: forcing mp4 onto a VP9/AV1+opus winner would
  # either re-encode or mux streams QuickTime can't index. %(ext)s lets
  # yt-dlp pick the honest container for whatever codecs win.
  echo "   downloading via yt-dlp → ${OUTDIR}/${stem}.*"
  if yt-dlp \
      -f "bestvideo+bestaudio/best" \
      -o "${OUTDIR}/${stem}.%(ext)s" \
      --no-overwrites \
      "$watch_url" 2>&1 | sed 's/^/   /'; then
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
# Uses the 9-strategy vimeo_scrape_embed_ids scraper; strips |referer suffix
# so callers receive bare IDs (one per line).
extract_vimeo_from_page() {
  local url="$1"
  local embed_data
  embed_data=$(vimeo_scrape_embed_ids "$url") || return 1
  echo "$embed_data" | cut -d'|' -f1
}

# Pure parser: HTML → YouTube video IDs, one per line, deduped, order kept.
# Matches the id in every form a page can carry it:
#   - plain markup: youtube.com/embed/<id> (also -nocookie), watch?v=<id>,
#     youtu.be/<id>, shorts/live/v paths, i.ytimg.com/vi/<id>/ thumbnails
#     (lite-embed/lazyload patterns that only paint the poster until click)
#   - URL-encoded copies of the same (%2F / %3F / %3D, one or two encoding
#     levels): Squarespace stores the Embedly iframe HTML-escaped inside a
#     data-block-json attribute, so the id only ever appears as
#     youtube.com%2Fembed%2F<id> / watch%3Fv%3D<id> — no plain form exists
#     anywhere in the served page.
# "videoseries" is the playlist embed's literal path token — exactly 11 chars
# of the id charset — and must be excluded.
youtube_ids_from_html() {
  local html="$1"
  local sl='(/|%2F|%252F)' q='(\?|%3F|%253F)' eq='(=|%3D|%253D)'
  local ids
  ids="$(grep -oiE "(youtube(-nocookie)?\.com${sl}(embed|shorts|live|v)${sl}|youtube\.com${sl}watch${q}v${eq}|youtu\.be${sl}|ytimg\.com${sl}vi(_webp)?${sl})[A-Za-z0-9_-]{11}" <<< "$html" \
    | grep -oE '[A-Za-z0-9_-]{11}$' \
    | grep -vx 'videoseries' \
    | awk '!seen[$0]++')" || true
  [[ -n "$ids" ]] || return 1
  echo "$ids"
}

# Extract YouTube video IDs from a webpage (network wrapper over the parser).
# Echoes one ID per line; returns 1 if none found.
extract_youtube_from_page() {
  local url="$1"
  local html
  html="$(curl -sL --max-time 15 -A "$UA" "$url" 2>/dev/null)" || return 1
  [[ -n "$html" ]] || return 1
  youtube_ids_from_html "$html"
}

# ── Squarespace native video discovery ──────────────────────────────────────
#
# Squarespace's own video hosting (video.squarespace-cdn.com) renders no
# <video src>, no iframe, and no manifest URL in the served HTML — the player
# block carries an HTML-escaped JSON config (data-config-video) whose
# alexandriaUrl is a {variant} template:
#   https://video.squarespace-cdn.com/content/v1/<libraryId>/<systemDataId>/{variant}
# so every URL-shaped extractor (Mux/Vimeo/YouTube/direct-media) missed it and
# the page died in the image pipeline (marzmiller.com). The master playlist is
# <base>/playlist.m3u8 — public and unsigned; it hands out freshly signed
# variant playlists (AES-128 segments, public /key/), so yt-dlp takes it
# end-to-end. The top HLS rung (h264 1080p) is the public ceiling: no
# progressive/source/original/download variant exists (all probed → 404).
#
# Pure parser: HTML → playlist.m3u8 URLs, one per line, deduped, order kept.
# Matches the base by host+path shape alone (self-attributing), so the
# {variant} template, a poster /thumbnail reference, or an explicit playlist
# URL all collapse onto the same base.
squarespace_video_urls_from_html() {
  local html="$1"
  local bases
  bases="$(grep -oE 'https://video\.squarespace-cdn\.com/content/v1/[A-Za-z0-9]+/[A-Za-z0-9-]+' <<< "$html" \
    | awk '!seen[$0]++')" || true
  [[ -n "$bases" ]] || return 1
  local b
  while IFS= read -r b; do
    echo "${b}/playlist.m3u8"
  done <<< "$bases"
}

# Extract Squarespace native-video playlist URLs from a webpage (network
# wrapper over the parser). Echoes one URL per line; returns 1 if none found.
extract_squarespace_video_from_page() {
  local url="$1"
  local html
  html="$(curl -sL --max-time 15 -A "$UA" "$url" 2>/dev/null)" || return 1
  [[ -n "$html" ]] || return 1
  squarespace_video_urls_from_html "$html"
}

# ── Self-hosted / direct media discovery ────────────────────────────────────
#
# Not every video page is a Mux or Vimeo embed. Plenty of production-company,
# agency and portfolio sites drop a plain progressive file straight into the
# markup — `<video src="…mp4">` — or reference it from a CMS JSON island
# (Next.js `__NEXT_DATA__`, Nuxt `__NUXT__`, inline `window.__*` stores).
# Before this existed, such a page found no Mux/Vimeo IDs, fell through to the
# image probe pipeline, HEADed as `text/html`, and died on "no valid media
# format found" — the file was in the HTML the scraper had already fetched.
#
# Three tiers, first non-empty wins (most authoritative first):
#   1. <video src> / <source src>   — the element the page actually plays
#   2. og:video / twitter:player:stream meta — the publisher's declared file
#   3. JSON/JS string values ending in a media extension — CMS islands
#
# Tier 1 is deliberately narrow: it yields the ONE file the player is bound to,
# so a page that also carries a short autoplay teaser in its JSON (Division's
# `preview`) returns the full film alone rather than both. Tier 3 only runs
# when the markup has no player element at all (JS-injected src).
#
# Emits absolute URLs, one per line, deduped, order preserved.
extract_direct_media_from_page() {
  local url="$1"
  local html
  html="$(curl -sL --max-time 15 -A "$UA" "$url" 2>/dev/null)" || return 1
  [[ -n "$html" ]] || return 1
  direct_media_from_html "$url" "$html"
}

# Pure parser behind extract_direct_media_from_page: (page_url, html) → URLs.
# Split out so the offline test harness can cover the tiering and the
# relative-URL resolution without a network fetch.
direct_media_from_html() {
  local url="$1" html="$2"
  local base_scheme base_host base_dir

  base_scheme="$(sed -E 's#^(https?)://.*#\1#' <<< "$url")"
  base_host="$(sed -E 's#^(https?://[^/]+).*#\1#' <<< "$url")"
  base_dir="${url%%\?*}"; base_dir="${base_dir%/*}"

  # Resolve protocol-relative / absolute-path / relative refs against the page.
  _abs_url() {
    local u="$1"
    case "$u" in
      http://*|https://*) echo "$u" ;;
      //*)               echo "${base_scheme}:${u}" ;;
      /*)                echo "${base_host}${u}" ;;
      *)                 echo "${base_dir}/${u}" ;;
    esac
  }

  local exts='mp4|m4v|webm|mov|mkv|m3u8|mpd|mp3|m4a|flac|wav|aac|ogg|opus'
  local hits=""

  # Tier 1 — the bound player element.
  hits="$(grep -oiE '<(video|source)[^>]+>' <<< "$html" \
    | grep -oiE '(src|data-src)[[:space:]]*=[[:space:]]*"[^"]+"' \
    | sed -E 's/^[^"]*"//; s/"$//' \
    | grep -iE "\.(${exts})(\?|#|$)" || true)"

  # Tier 2 — publisher-declared social/player file.
  if [[ -z "$hits" ]]; then
    hits="$(grep -oiE '<meta[^>]+(og:video(:secure_url|:url)?|twitter:player:stream)[^>]*>' <<< "$html" \
      | grep -oiE 'content[[:space:]]*=[[:space:]]*"[^"]+"' \
      | sed -E 's/^[^"]*"//; s/"$//' \
      | grep -iE "\.(${exts})(\?|#|$)" || true)"
  fi

  # Tier 3 — CMS JSON island / inline JS string values.
  if [[ -z "$hits" ]]; then
    hits="$(grep -oE '"[^"]*\.('"$exts"')(\\?[^"]*)?"' <<< "$html" \
      | sed -E 's/^"//; s/"$//' \
      | grep -E '^(https?:)?//|^/' || true)"
  fi

  [[ -n "$hits" ]] || return 1

  local u seen=""
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    u="${u//&amp;/&}"
    u="$(_abs_url "$u")"
    # dedupe, preserving discovery order
    case "$seen" in *"|${u}|"*) continue ;; esac
    seen="${seen}|${u}|"
    echo "$u"
  done <<< "$hits"
  return 0
}

# ── Apple Music / iTunes artwork discovery ──────────────────────────────────
#
# Given an Apple Music (music.apple.com) or iTunes Store (itunes.apple.com)
# page URL — album, song (album + ?i=), artist, playlist, music-video, etc. —
# discover the primary artwork as an mzstatic resizer URL.
#
# The page's `og:image` meta tag carries the canonical artwork ASSET PATH:
#   - albums/songs → the square cover, Music*/…/<id>.rgb.jpg
#   - artists      → the identity photo, AMCArtistImages*/…/ami-identity-*.png
# It is only ever exposed at a small CROPPED social-card spec (1200x630wp for
# albums, 1200x630cw for artists), but cdn_resolve_mzstatic discards that spec
# and requests the full uncropped source — so og:image alone recovers the
# master.  Verified: album 1200x630wp → 3000x3000 (square cover, not the wide
# crop); artist 1200x630cw → 5998x5998 (full uncropped photo).
#
# This is more uniform than the iTunes Lookup API, which returns artwork for
# collections/tracks but NOT for artists (artist images live only in the web
# page / amp-api).  og:image is one tokenless code path for every entity type.
#
# Echoes the og:image URL; returns 1 if not an Apple URL or no og:image found.
extract_apple_artwork() {
  local url="$1"
  [[ "$url" =~ ^https?://(music|itunes)\.apple\.com/ ]] || return 1
  local html og
  html="$(curl -sL --max-time 20 -H "User-Agent: $UA" "$url" 2>/dev/null)" || return 1
  og="$(printf '%s' "$html" \
        | grep -oE '<meta property="og:image"[^>]*content="[^"]+"' \
        | head -1 \
        | grep -oE 'content="[^"]+"' \
        | sed -E 's/^content="//; s/"$//; s/&amp;/\&/g')"
  [[ -n "$og" ]] || return 1
  echo "$og"
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
  --referer URL        Embedding page URL, sent as Referer for domain-locked
                       embeds (--referrer also accepted)

Examples:
  app.sh -c cookies.txt --vimeo 385365963
  app.sh -c cookies.txt --vimeo https://vimeo.com/252387977
  app.sh -c cookies.txt --vimeo https://example.com/page-with-embed
  app.sh -c cookies.txt --vimeo --force-download urls.txt
USAGE
  exit 1
}

# Normalize one input URL: drop stray CR, trim whitespace, and supply a missing
# scheme. A value copied out of devtools / an address bar routinely arrives bare
# (`player.vimeo.com/progressive_redirect/…`). curl tolerates that, aria2c does
# NOT — it dies with "Unrecognized URI or unsupported protocol" — so the whole
# probe pipeline would succeed, pick a winner, and only then fail at download.
# Protocol-relative `//host/…` gets https: as well.
normalize_url() {
  local u="$1"
  u="${u//$'\r'/}"
  u="${u#"${u%%[![:space:]]*}"}"   # ltrim
  u="${u%"${u##*[![:space:]]}"}"   # rtrim
  [[ -z "$u" ]] && return 1
  # A scheme counts only at the START — `x.com/a?next=https://y` carries one
  # in its query and used to pass as already-schemed. Host-shaped means a
  # dotted name (labels may hold digits and `_`, so IPv4 and cdn_1.example.com
  # qualify), or `localhost`, with an optional userinfo@ and :port — the
  # classes aria2c rejects bare. Anything else is left alone so a genuinely
  # malformed input still surfaces as itself in the log.
  if [[ "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    :
  elif [[ "$u" == //* ]]; then
    u="https:${u}"
  elif [[ "$u" =~ ^([^/@[:space:]]+@)?(([A-Za-z0-9_-]+\.)+[A-Za-z0-9_-]+|localhost)(:[0-9]+)?([/?#].*)?$ ]]; then
    u="https://${u}"
  fi
  printf '%s\n' "$u"
}

read_urls() {
  local line norm
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    norm="$(normalize_url "$line")" || continue
    echo "$norm"
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
      elif [[ "$arg" != *://* && "$arg" != */* && "$arg" =~ \.(txt|lst|list|urls|csv|har|json)$ ]]; then
        # a list-file NAME with no such file: normalize_url reads `urls.txt` as
        # a host (dotted, TLD-shaped), the run probed https://urls.txt, and the
        # summary tallied one phantom failure with no "no such file" anywhere.
        echo "!! no such file: $arg (expected a URL, or an existing URL list)" >&2
      else
        # Route argv through the same reader as files/stdin. An argument pasted
        # with a trailing newline inside the quotes used to become TWO urls —
        # the second empty, which then ran the full pipeline and was tallied as
        # a phantom failure — and a scheme-less one went unnormalized.
        while IFS= read -r u; do urls+=("$u"); done < <(read_urls <<< "$arg")
      fi
    done
  else
    usage
  fi

  [[ ${#urls[@]} -gt 0 ]] && printf '%s\n' "${urls[@]}"
}

# ════════════════════════════════════════════════════════════════════════════
# PIPELINE — each URL travels through these stops in order (see process_url).
# ════════════════════════════════════════════════════════════════════════════

# ────────────────────────────────────────────────────────────────────────────
# STOP 1 · Apple Music / iTunes page → rewrite URL to its og:image artwork.
# ────────────────────────────────────────────────────────────────────────────
stage_fbsbx_media() {
  # ── Facebook lookaside media → lossless PNG master ───────────────────────
  # Intercept lookaside.fbsbx.com raster media before the content-type-driven
  # probe pipeline (which can't classify the octet-stream PNG response). Force
  # transcode_extension=png and download the lossless master directly.
  local png_url
  png_url="$(fbsbx_png_url "$url")" || return 0

  echo "   Facebook lookaside media — forcing lossless PNG transcode..."
  local mid
  mid="$(sed -E 's/.*[?&]media_id=([0-9]+).*/\1/' <<< "$url")"
  [[ -n "$CUSTOM_FILENAME" ]] && stem="$CUSTOM_FILENAME" || stem="fbsbx_${mid}"

  # Confirm the PNG transcode is real (magic bytes) before committing to it.
  local real_fmt
  real_fmt="$(verify_magic "$png_url")"
  if [[ "$real_fmt" != "png" ]]; then
    echo "   !! PNG transcode unavailable (got ${real_fmt:-none}) — falling through to normal pipeline" >&2
    return 0
  fi

  local info cl
  info="$(head_info "$png_url")"
  cl="$(sed -n '2p' <<< "$info")"
  echo "   master → $png_url"

  local out="${OUTDIR}/${stem}.png"
  if [[ -f "$out" ]] && [[ "${cl:-0}" -gt 0 ]] 2>/dev/null; then
    local local_size
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if [[ "$local_size" -eq "$cl" ]]; then
      echo "   SKIP (already exists, ${cl} bytes): $out"
      (( OK++ )) || true; _SKIP=1; return
    fi
  fi

  echo "   BEST → PNG ($(( ${cl:-0} / 1024 )) KB, lossless master)"
  echo "   downloading → $out"
  # aria2c (parallel, resumable-safe via --allow-overwrite) → curl fallback.
  if command -v aria2c >/dev/null 2>&1 && \
     aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" --allow-overwrite=true --auto-file-renaming=false \
       -x 16 -s 16 -k 1M --header="User-Agent: $UA" \
       -o "$(basename "$out")" -d "$OUTDIR" "$png_url" --quiet 2>/dev/null; then
    (( OK++ )) || true
  elif curl -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" -A "$UA" -o "$out" "$png_url" 2>/dev/null; then
    (( OK++ )) || true
  else
    echo "   !! download failed" >&2
    (( FAIL++ )) || true
  fi
  _SKIP=1; return
}

stage_apple_artwork() {
  # ── Apple Music / iTunes page → artwork URL ──────────────────────────────
  # Rewrite the page URL to its og:image artwork asset, then let the normal
  # pipeline run: the og:image ends in .jpg/.png so it skips video page-scrape,
  # and cdn_resolve_mzstatic upgrades it to the full lossless master.
  if [[ "$url" =~ ^https?://(music|itunes)\.apple\.com/ ]]; then
    echo "   Apple Music page — discovering artwork..."
    apple_art="$(extract_apple_artwork "$url")" || true
    if [[ -n "$apple_art" ]]; then
      echo "   artwork → $apple_art"
      url="$apple_art"
      [[ -z "$CUSTOM_FILENAME" ]] && stem="$(basename_from_url "$url")"
    else
      echo "   !! no artwork found on Apple Music page" >&2
      (( FAIL++ )) || true
      _SKIP=1; return
    fi
  fi
  return 0
}

stage_reddit_post() {
  # ── Reddit post → i.redd.it masters for every image in the post ──────────
  # Reddit's content pages and JSON API are IP-gated for scripted clients (an
  # HTML "blocked" wall on www/old/api, regardless of UA or TLS fingerprint),
  # but three surfaces stay open to plain curl:
  #   1. per-post RSS  www.reddit.com/comments/<id>/.rss — canonical permalink
  #      + the selftext body (inline text-post images). First <entry> is the
  #      post (t3_); everything after is comments — cut there so comment
  #      images are never harvested.
  #   2. embed.reddit.com/<permalink> — server-rendered post: every gallery
  #      page (verified: all 12 of a 12-item gallery), no comments, plus the
  #      post JSON (escaped) in <shreddit-screenview-data> whose url field
  #      carries the content link for link posts.
  #   3. i.redd.it — the stored master itself.
  # preview.redd.it refs from both surfaces host-swap to i.redd.it via
  # cdn_resolve_reddit_preview; even the native-width preview is a lossy
  # re-encode (1080w ≈ 162 KB vs 530 KB master on the same photo).
  case "$url" in
    *reddit.com/*|http://redd.it/*|https://redd.it/*) : ;;
    *) return 0 ;;
  esac

  local target="$url"
  # Share links (/r/<sub>/s/<token>) carry no post id — resolve the redirect
  # (www serves redirects even where it gates content pages).
  if [[ "$url" =~ reddit\.com/r/[A-Za-z0-9_]+/s/ ]]; then
    local loc
    loc="$(curl -s -o /dev/null "${CURL_TIMEOUT_OPTS[@]}" -A "$UA" -w '%{redirect_url}' "$url" 2>/dev/null)" || true
    [[ -n "$loc" ]] && target="$loc"
  fi

  local pid
  pid="$(reddit_post_id_from_url "$target")" || return 0   # not a post URL — fall through

  echo "   Reddit post ${pid} — enumerating images..."

  local rss entry permalink
  rss="$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" -A "$UA" "https://www.reddit.com/comments/${pid}/.rss" 2>/dev/null)" || true
  entry="${rss%%</entry>*}"
  permalink="$(echo "$entry" | grep -oE "https://www\.reddit\.com/(r|user)/[A-Za-z0-9_-]+/comments/${pid}/[A-Za-z0-9_]*" | head -1)" || true
  # RSS gated/empty? Fall back to a permalink present in the input itself.
  if [[ -z "$permalink" ]]; then
    permalink="$(echo "$target" | grep -oE "https?://[a-z.]*reddit\.com/(r|user)/[A-Za-z0-9_-]+/comments/${pid}[A-Za-z0-9_/]*")" || true
  fi

  local embed_html=""
  if [[ -n "$permalink" ]]; then
    embed_html="$(curl -sL "${CURL_TIMEOUT_OPTS[@]}" -A "$UA" "https://embed.reddit.com/${permalink#*reddit.com/}" 2>/dev/null)" || true
  fi

  # Union the media refs from both surfaces → dedupe on the i.redd.it master.
  local refs
  refs="$( { echo "$entry"; echo "$embed_html"; } \
    | grep -oE 'https://(preview|i)\.redd\.it/[A-Za-z0-9._-]+\.(jpe?g|png|gif|webp)' \
    | sort -u)" || true

  local -a masters=()
  local seen=" " r m
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    if [[ "$r" == https://i.redd.it/* ]]; then
      m="$r"
    else
      m="$(cdn_resolve_reddit_preview "$r")" || continue
    fi
    [[ "$seen" == *" $m "* ]] && continue
    seen="${seen}${m} "
    masters+=("$m")
  done <<< "$refs"

  if [[ ${#masters[@]} -eq 0 ]]; then
    # No self-hosted media: link post? The post JSON in the embed page carries
    # the outbound URL — hand it to the normal pipeline so its own CDN
    # resolver gets a shot (imgur/flickr/etc.).
    local post_url
    post_url="$(echo "$embed_html" \
      | grep -oE '&quot;url&quot;:&quot;([^&]|&amp;)+' | head -1 \
      | sed -e 's/^&quot;url&quot;:&quot;//' -e 's/&amp;/\&/g')" || true
    case "$post_url" in
      *v.redd.it*)
        echo "   !! Reddit video post (v.redd.it) — image handler only, skipping" >&2
        (( FAIL++ )) || true; _SKIP=1; return ;;
      http://*|https://*)
        if [[ "$post_url" != *reddit.com* && "$post_url" != *redd.it* ]]; then
          echo "   link post → $post_url"
          url="$post_url"
          [[ -z "$CUSTOM_FILENAME" ]] && stem="$(basename_from_url "$url")"
          return 0
        fi ;;
    esac
    echo "   !! no images found on Reddit post (gated/deleted/text-only?)" >&2
    (( FAIL++ )) || true
    _SKIP=1; return
  fi

  local n=${#masters[@]} idx=0 dl_ok=0 dl_fail=0
  echo "   found ${n} image(s)"
  for m in "${masters[@]}"; do
    (( idx++ )) || true
    local mbase="${m##*/}"
    local out="${OUTDIR}/${mbase}"
    if [[ -n "$CUSTOM_FILENAME" ]]; then
      if (( n > 1 )); then out="${OUTDIR}/${CUSTOM_FILENAME}_${idx}.${mbase##*.}"
      else out="${OUTDIR}/${CUSTOM_FILENAME}.${mbase##*.}"; fi
    fi
    (( n > 1 )) && echo "   ── image ${idx}/${n}"

    # Magic-byte check: removed/suspended media serves an HTML or PNG error.
    local real_fmt
    real_fmt="$(verify_magic "$m")"
    if [[ "$real_fmt" == "unknown" ]]; then
      echo "   !! not an image (removed?): $m" >&2
      (( dl_fail++ )) || true
      continue
    fi

    local info cl
    info="$(head_info "$m")" || true
    cl="$(sed -n '2p' <<< "$info")"
    if [[ -f "$out" ]] && [[ "${cl:-0}" -gt 0 ]] 2>/dev/null; then
      local lsz
      lsz="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
      if [[ "$lsz" -eq "$cl" ]]; then
        echo "   SKIP (already exists, ${cl} bytes): $out"
        (( dl_ok++ )) || true
        continue
      fi
    fi

    echo "   master → $m ($(( ${cl:-0} / 1024 )) KB)"
    if command -v aria2c >/dev/null 2>&1 && \
       aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" --allow-overwrite=true --auto-file-renaming=false \
         -x 16 -s 16 -k 1M --header="User-Agent: $UA" \
         -o "$(basename "$out")" -d "$OUTDIR" "$m" --quiet 2>/dev/null; then
      echo "   saved → $out"
      (( dl_ok++ )) || true
    elif curl -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" -A "$UA" -o "$out" "$m" 2>/dev/null; then
      echo "   saved → $out"
      (( dl_ok++ )) || true
    else
      echo "   !! download failed: $m" >&2
      (( dl_fail++ )) || true
    fi
  done
  (( OK += dl_ok )) || true
  (( FAIL += dl_fail )) || true
  _SKIP=1; return
}

# ────────────────────────────────────────────────────────────────────────────
# STOP 2 · Video platforms — direct Mux/Vimeo + embedded-player page scrape.
# ────────────────────────────────────────────────────────────────────────────
stage_video_intercept() {
  # ── Video platform early intercepts — bypass normal probe pipeline ───────

  # Direct Mux stream URL
  if [[ "$url" == *"stream.mux.com/"* ]]; then
    mux_rc=0
    handle_mux "$url" "$stem" || mux_rc=$?
    if [[ $mux_rc -eq 0 ]]; then (( OK++ )) || true; _SKIP=1; return
    elif [[ $mux_rc -eq 2 ]]; then echo "   !! download failed" >&2; (( FAIL++ )) || true; _SKIP=1; return; fi

  # Direct Vimeo URL
  elif [[ "$url" == *"vimeo.com/"* ]]; then
    vim_rc=0
    handle_vimeo "$url" "$stem" "$VIMEO_REFERER" || vim_rc=$?
    if [[ $vim_rc -eq 0 ]]; then (( OK++ )) || true; _SKIP=1; return
    elif [[ $vim_rc -eq 2 ]]; then echo "   !! download failed" >&2; (( FAIL++ )) || true; _SKIP=1; return; fi

  # Direct YouTube URL
  elif [[ "$url" =~ youtu\.be/|youtube(-nocookie)?\.com/(watch|embed/|shorts/|live/) ]]; then
    yt_rc=0
    handle_youtube "$url" "$stem" || yt_rc=$?
    if [[ $yt_rc -eq 0 ]]; then (( OK++ )) || true; _SKIP=1; return
    elif [[ $yt_rc -eq 2 ]]; then echo "   !! download failed" >&2; (( FAIL++ )) || true; _SKIP=1; return; fi

  # Direct Squarespace native-video URL — the {variant} template, the poster
  # /thumbnail, or the playlist itself. Without this arm the URL the registry
  # names as the lever was a dead input on argv: the page gate below excludes
  # .m3u8, and is_squarespace then claimed the host for the IMAGE ladder
  # (?format=original + an image Accept header -> "no valid media format").
  # The pure parser rebuilds <base>/playlist.m3u8 from any of those shapes.
  elif [[ "$url" == *"video.squarespace-cdn.com/content/v1/"* ]]; then
    sq_rc=0; sq_url=""
    sq_url="$(squarespace_video_urls_from_html "$url")" || true
    if [[ -z "$sq_url" ]]; then
      echo "   !! unrecognized video.squarespace-cdn.com URL (want …/content/v1/<lib>/<asset>/…)" >&2
      (( FAIL++ )) || true; _SKIP=1; return
    fi
    download_direct_media "${sq_url%%$'\n'*}" "$stem" || sq_rc=$?
    if [[ $sq_rc -eq 0 ]]; then (( OK++ )) || true
    else echo "   !! download failed" >&2; (( FAIL++ )) || true; fi
    _SKIP=1; return

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
        rc=0
        handle_mux "$mux_url" "$local_stem" || rc=$?
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
          rc=0
          handle_vimeo "vimeo:${vid}" "$local_stem" "$url" || rc=$?
          if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
          elif [[ $rc -eq 2 ]]; then echo "   !! download failed" >&2; (( vid_fail++ )) || true; fi
        done <<< "$vimeo_ids"
        (( OK += vid_ok )) || true
        (( FAIL += vid_fail )) || true
        (( TOTAL += vid_ok + vid_fail - 1 )) || true
        page_handled=true
      fi
    fi

    # Try YouTube extraction — catches Squarespace/Embedly-wrapped embeds
    # whose video id only appears URL-encoded inside a data-block-json
    # attribute (no plain iframe exists in the served page).
    if ! $page_handled; then
      youtube_ids="$(extract_youtube_from_page "$url")" || true
      if [[ -n "$youtube_ids" ]]; then
        vid_count="$(echo "$youtube_ids" | wc -l | tr -d ' ')"
        echo "   found ${vid_count} YouTube video(s)"
        vid_ok=0; vid_fail=0; vid_idx=0
        while IFS= read -r vid; do
          (( vid_idx++ )) || true
          local_stem="$stem"
          (( vid_count > 1 )) && local_stem="${stem}_${vid_idx}"
          (( vid_count > 1 )) && { echo ""; echo "   ── video ${vid_idx}/${vid_count}"; }
          rc=0
          handle_youtube "youtube:${vid}" "$local_stem" || rc=$?
          if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
          elif [[ $rc -eq 2 ]]; then echo "   !! download failed" >&2; (( vid_fail++ )) || true; fi
        done <<< "$youtube_ids"
        (( OK += vid_ok )) || true
        (( FAIL += vid_fail )) || true
        (( TOTAL += vid_ok + vid_fail - 1 )) || true
        page_handled=true
      fi
    fi

    # Try Squarespace native video — the player block carries only an escaped
    # JSON {variant} template, so no URL-shaped media ref exists for the
    # direct-media tiers to find. The playlist URL is rebuilt from the
    # alexandriaUrl base and handed to download_direct_media's manifest path.
    if ! $page_handled; then
      sqsp_videos="$(extract_squarespace_video_from_page "$url")" || true
      if [[ -n "$sqsp_videos" ]]; then
        vid_count="$(echo "$sqsp_videos" | wc -l | tr -d ' ')"
        echo "   found ${vid_count} Squarespace video(s)"
        vid_ok=0; vid_fail=0; vid_idx=0
        while IFS= read -r surl; do
          (( vid_idx++ )) || true
          local_stem="$stem"
          (( vid_count > 1 )) && local_stem="${stem}_${vid_idx}"
          (( vid_count > 1 )) && { echo ""; echo "   ── video ${vid_idx}/${vid_count}"; }
          rc=0
          download_direct_media "$surl" "$local_stem" "$url" || rc=$?
          if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
          else (( vid_fail++ )) || true; fi
        done <<< "$sqsp_videos"
        (( OK += vid_ok )) || true
        (( FAIL += vid_fail )) || true
        (( TOTAL += vid_ok + vid_fail - 1 )) || true
        page_handled=true
      fi
    fi

    # Try self-hosted / direct progressive media (plain <video src="…mp4">).
    # Runs last: Mux, Vimeo and YouTube are richer platform handlers, so they
    # get first refusal. This catches production-company and portfolio sites
    # that serve a progressive file straight off their own asset host.
    if ! $page_handled; then
      direct_media="$(extract_direct_media_from_page "$url")" || true
      if [[ -n "$direct_media" ]]; then
        med_count="$(echo "$direct_media" | wc -l | tr -d ' ')"
        echo "   found ${med_count} direct media file(s)"
        vid_ok=0; vid_fail=0; vid_idx=0
        while IFS= read -r murl; do
          (( vid_idx++ )) || true
          local_stem="$stem"
          (( med_count > 1 )) && local_stem="${stem}_${vid_idx}"
          (( med_count > 1 )) && { echo ""; echo "   ── file ${vid_idx}/${med_count}"; }
          rc=0
          download_direct_media "$murl" "$local_stem" || rc=$?
          if [[ $rc -eq 0 ]]; then (( vid_ok++ )) || true
          else (( vid_fail++ )) || true; fi
        done <<< "$direct_media"
        (( OK += vid_ok )) || true
        (( FAIL += vid_fail )) || true
        (( TOTAL += vid_ok + vid_fail - 1 )) || true
        page_handled=true
      fi
    fi

    if $page_handled; then _SKIP=1; return; fi
    # no embedded videos found — fall through to normal pipeline
  fi
  return 0
}

# Download a progressive media URL discovered on a page.
# Keeps the media extension from the URL, honours skip-if-present against
# Content-Length, and uses aria2c -c (safe here: unlike the image path, a
# direct page-embedded media URL is a fixed asset, not a probe winner that can
# change between runs, so resuming can never splice two different files).
# MREF (optional) is the embedding page, sent as Referer on the manifest path.
download_direct_media() {
  local murl="$1" mstem="$2" mref="${3:-}"
  local ext info cl out

  ext="$(sed -E 's/^.*\.([A-Za-z0-9]{2,5})(\?.*)?$/\1/' <<< "$murl" | tr 'A-Z' 'a-z')"
  [[ "$ext" =~ ^[a-z0-9]{2,5}$ ]] || ext="mp4"

  # Streaming manifests need yt-dlp, not a byte fetch.
  if [[ "$ext" == "m3u8" || "$ext" == "mpd" ]]; then
    if ! command -v yt-dlp >/dev/null 2>&1; then
      echo "   !! cannot fetch stream manifest (yt-dlp required): $murl" >&2
      return 1
    fi
    echo "   stream manifest → $murl"
    # yt-dlp's own words stay visible (an expired signature, a 403 on the key,
    # a missing ffmpeg for AES-128 HLS, a throttle) — a failure here used to be
    # reported as "yt-dlp required" with the tool installed. Same posture as
    # the Vimeo path: the site UA, the embedding page as Referer when the
    # caller knows it (signed Squarespace variants are served to the page's
    # origin), and retries — a brief 403 on a key fetch is not a missing tool.
    local ydl=(--no-warnings --retries 10 --fragment-retries 10 --user-agent "$UA")
    [[ -n "$mref" ]] && ydl+=(--referer "$mref")
    if yt-dlp "${ydl[@]}" -o "${OUTDIR}/${mstem}.%(ext)s" "$murl" 2>&1 | sed 's/^/   /'; then
      return 0
    fi
    echo "   !! stream manifest download failed (yt-dlp output above): $murl" >&2
    return 1
  fi

  info="$(head_info "$murl")" || true
  cl="$(sed -n '2p' <<< "$info")"
  out="${OUTDIR}/${mstem}.${ext}"

  echo "   media → $murl"
  if [[ -f "$out" ]] && [[ "${cl:-0}" -gt 0 ]] 2>/dev/null; then
    local local_size
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if [[ "$local_size" -eq "$cl" ]]; then
      echo "   SKIP (already exists, ${cl} bytes): $out"
      return 0
    fi
  fi

  [[ "${cl:-0}" -gt 0 ]] 2>/dev/null && \
    echo "   BEST → $(tr 'a-z' 'A-Z' <<< "$ext") ($(( cl / 1048576 )) MB)"
  echo "   downloading → $out"
  if command -v aria2c >/dev/null 2>&1 && \
     aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" -c --auto-file-renaming=false \
       -x 16 -s 16 -k 1M --header="User-Agent: $UA" \
       -o "$(basename "$out")" -d "$OUTDIR" "$murl" --quiet 2>/dev/null; then
    return 0
  elif curl -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" -A "$UA" -o "$out" "$murl" 2>/dev/null; then
    return 0
  fi
  echo "   !! download failed: $murl" >&2
  return 1
}

# ────────────────────────────────────────────────────────────────────────────
# STOP 3 · CDN resolution + baseline probe (original & resolved) + dims.
# ────────────────────────────────────────────────────────────────────────────
stage_cdn_resolve_baseline() {
  # CDN resolution — rewrite URL to original/largest version
  echo "   resolving CDN..."
  resolved_url="$(cdn_resolve "$url")"

  # Cloudinary JPEG-origin fix: cdn_resolve_cloudinary appends `.png` to force a
  # lossless ceiling, but when the bare URL already serves the byte-exact source
  # upload (a JPEG), that `.png` is a lossless re-wrap bloat that wrongly wins the
  # format ladder. Prefer the bare original and suppress the ladder for it (below).
  CLOUDINARY_BARE_ORIGIN=false
  if [[ "$resolved_url" == *"/image/upload/"* && "$resolved_url" == *.png ]]; then
    cbm_url="$(cloudinary_bare_master "$resolved_url" 2>/dev/null || true)"
    if [[ -n "$cbm_url" ]]; then
      echo "   Cloudinary origin is byte-exact via bare URL → using it (the .png is a lossless re-wrap bloat)"
      resolved_url="$cbm_url"
      CLOUDINARY_BARE_ORIGIN=true
    fi
  fi

  # TownNews/BLOX (TNCMS): the page-referenced `.image.jpg` is capped at a fixed
  # 2,073,600 px area on ingest. The photographer's full-res delivery is stored
  # as a separate `.hires.jpg` resource that appears nowhere in the markup and
  # whose hash isn't derivable — only the site's public BLOX search API names it.
  TNCMS_HIRES=false
  if is_tncms_image_url "$resolved_url"; then
    tnh_out="$(tncms_hires_master "$resolved_url" 2>/dev/null || true)"
    tnh_url="$(sed -n '1p' <<< "$tnh_out")"
    TNCMS_ASSET_TITLE="$(sed -n '2p' <<< "$tnh_out")"
    if [[ -n "$tnh_url" ]]; then
      echo "   TNCMS hi_res master found via BLOX search API (page rendition is capped at 2.07 MP)"
      resolved_url="$tnh_url"
      TNCMS_HIRES=true
      # Keep the CMS's own photo-desk filename instead of the opaque hash stem.
      if [[ -z "$CUSTOM_FILENAME" && -n "${TNCMS_ASSET_TITLE:-}" ]]; then
        stem="${TNCMS_ASSET_TITLE%.*}"
        stem="${stem//\//_}"
      fi
    fi
  fi

  if [[ "$resolved_url" != "$url" ]]; then
    echo "   CDN resolved → $resolved_url"
    # The original URL's basename is often a transform-proxy artefact
    # (e.g. URL-encoded origin path on image-cdn.hypb.st). Re-derive the
    # stem from the resolved URL so the on-disk filename reflects the
    # actual asset. --filename always wins.
    # TNCMS already set the stem from the CMS's own photo-desk filename, which
    # beats the opaque `<hash>.hires` basename (and every hires file in a gallery
    # would otherwise differ only by hash).
    if [[ -z "$CUSTOM_FILENAME" ]] && ! ${TNCMS_HIRES:-false}; then
      resolved_stem="$(basename_from_url "$resolved_url")"
      [[ -n "$resolved_stem" && "$resolved_stem" != "$stem" ]] && stem="$resolved_stem"
    fi
    # probe original as fallback (source "O" = pre-resolution, subject to transcode checks)
    # EXCEPT for SKIMS imgix: the original carries imgix sizing params (e.g.
    # w=2619) and imgix's default fit=clip UPSCALES a smaller source to that
    # width (786×1128 source → fake 2619×3759, ~10× bytes of interpolated
    # detail). That upscale would beat the honest bare source on the size
    # tiebreaker. The resolved bare URL is the same asset's true master, so the
    # original adds only the upscale trap — skip it.
    if is_skims_imgix_url "$url"; then
      echo "   probing baseline (resolved source only — skipping imgix upscale)..."
    else
      echo "   probing baseline (original)..."
      baseline_probe "$url" "O"
    fi
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
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# STOP 4 · Format discovery — bitrate variants (A/V) or Accept/param/path (images).
# ────────────────────────────────────────────────────────────────────────────
stage_probe_formats() {
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
    # Shopify: cdn_resolve_shopify already produced the peak-fidelity URL
    # (?format=png — verified raw-RGB-pixel-identical to source). Probing
    # would issue ~16 wasted HEADs per image. Per shopify_learnings.md, the
    # only winning rendition is ?format=png; everything else is equal-or-worse
    # and ?format=tiff/avif/heic silently return JPEG.
    is_shopify_image_url "$probe_url" && skip_probes=true
    # Cloudinary bare-origin (see cloudinary_bare_master): probe_url is the bare,
    # byte-exact source upload. Any Accept/param/path re-encode (.png/.tif) would be
    # a pixel-identical lossless wrapper that only bloats bytes and wrongly wins the
    # format ladder — the exact trap this fix removes. Skip the ladder entirely.
    ${CLOUDINARY_BARE_ORIGIN:-false} && skip_probes=true
    # TNCMS hi_res: the bloximages resizer UPSCALES without clamping (?resize=N
    # above source returns interpolated pixels that win on size), ?quality= is
    # silently ignored, and .tif/.png/.original siblings all 404. Every rung of
    # the ladder is therefore dead or a fake-pixel trap.
    ${TNCMS_HIRES:-false} && skip_probes=true
    # Discogs (i.discogs.com): signed imgproxy — the signature covers the whole
    # path, so every extension swap 403s and query params are silently ignored
    # (byte-identical response → the ladder can only produce dead or duplicate
    # candidates). cdn_resolve_discogs already returned the API full-size uri,
    # which is the platform ceiling (600px stored cap).
    is_discogs_image_url "$probe_url" && skip_probes=true
    # Future PLC (cdn.mos.cms.futurecdn.net): cdn_resolve_futurecdn already
    # returned the bare stored upload. The extension is locked to the stored
    # object's format (.jpg/.tif/.webp swaps all 404) and query params are
    # ignored byte-for-byte, so the ladder can only produce dead or duplicate
    # candidates.
    is_futurecdn_image_url "$probe_url" && skip_probes=true

    if ! $skip_probes; then
      echo "   probing Accept headers..."
      accept_probe "$probe_url"

      echo "   probing query parameters..."
      param_probe "$probe_url"

      echo "   probing path extensions..."
      path_probe "$probe_url"
    fi
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# STOP 5 · Pick the winning candidate; verify magic bytes; reject transcodes.
# ────────────────────────────────────────────────────────────────────────────
stage_select_winner() {
  # select winner, verify magic bytes, re-select if server lied
  while true; do
    winner="$(select_best)" || {
      echo "   !! SKIP — no valid media format found" >&2
      (( FAIL++ )) || true
      _SKIP=1; return
    }

    IFS=: read -r _pri _size win_fmt win_source win_url <<< "$winner"
    # reassemble URL (it may contain colons after the source+url fields)
    win_url="${winner#*:*:*:*:}"

    # verify actual content via magic bytes
    echo "   verifying ${win_fmt}..."
    real_fmt="$(verify_magic "$win_url")"
    # internal reclassifications — magic bytes still say the base format
    check_fmt="$win_fmt"
    [[ "$check_fmt" == "png-indexed" || "$check_fmt" == "png-grayscale" ]] && check_fmt="png"
    check_fmt="${check_fmt%-transcode}"
    if [[ "$real_fmt" != "unknown" && "$real_fmt" != "$check_fmt" ]]; then
      echo "   server lied: claims ${win_fmt}, actually ${real_fmt}"
      # remove this fake candidate, fix its entry to reflect real format
      real_pri="$(fmt_priority "$real_fmt")"
      replace_winner_candidate "${real_pri}:${_size}:${real_fmt}:${win_source}:${win_url}"
      continue  # re-select with corrected data
    fi

    # PNG color-type demotion: indexed PNGs (type 3) are palette-quantized;
    # grayscale PNGs (type 0 / 4) drop color entirely. Both are strictly
    # worse than a full-color baseline JPG at the same dimensions. Demote
    # to priority 4 (between JPG and WEBP) so a truecolor baseline wins.
    # Grayscale only demotes against a color baseline (JPG/WEBP/etc) —
    # a genuinely grayscale source should still be kept.
    if [[ "$win_fmt" == "png" ]]; then
      pct="$(png_color_type "$win_url")"
      demote_tag=""
      demote_msg=""
      case "$pct" in
        indexed)
          demote_tag="png-indexed"
          demote_msg="palette-indexed PNG detected (demoting below JPG)"
          ;;
        grayscale|grayscale-alpha)
          # only demote if baseline was a color format — grayscale source is legit otherwise
          if [[ "$BASELINE_FMT" == "jpg" || "$BASELINE_FMT" == "jpeg" || "$BASELINE_FMT" == "webp" || "$BASELINE_FMT" == "tif" || "$BASELINE_FMT" == "tiff" ]]; then
            demote_tag="png-grayscale"
            demote_msg="grayscale PNG transcode of color ${BASELINE_FMT} (demoting below JPG)"
          fi
          ;;
      esac
      if [[ -n "$demote_tag" ]]; then
        echo "   $demote_msg"
        real_pri="$(fmt_priority "$demote_tag")"
        replace_winner_candidate "${real_pri}:${_size}:${demote_tag}:${win_source}:${win_url}"
        continue  # re-select — a truecolor JPG may now win
      fi
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
          replace_winner_candidate "90:${_size}:${win_fmt}-transcode:${win_source}:${win_url}"
          continue  # re-select — baseline or path-probe candidate should win
        fi
      fi

      # P2: same-format pre-resolution bloat. When CDN resolution succeeded
      # and the winner is the original URL (source "O") with the SAME format
      # AND SAME dimensions as the resolved baseline, the proxy is just
      # re-encoding the resolved source at higher quality settings — bigger
      # bytes, identical pixels (PSNR ~56 dB).  RebelMouse's image.jpg?id=N
      # is the canonical example: 473 KB proxy default vs 436 KB S3 origin,
      # both 2000x2500 JPEG.  The size-tiebreaker in select_best would pick
      # the bloat without this check.
      if [[ "$win_source" == "O" ]] && (( win_pri_n == base_pri_n )); then
        win_dims="${win_dims:-$(_image_dims "$win_url" "$win_fmt" 2>/dev/null)}" || win_dims=""
        if [[ -n "$win_dims" && "$win_dims" == "$BASELINE_DIMS" ]]; then
          echo "   pre-resolution original is bloated re-encode (same dims as resolved ${win_dims}) — demoting"
          replace_winner_candidate "90:${_size}:${win_fmt}-transcode:${win_source}:${win_url}"
          continue  # re-select — the resolved-URL candidate should win
        fi
      fi
    fi

    break
  done
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# STOP 6 · Map format → extension, skip-if-present, download the winner.
# ────────────────────────────────────────────────────────────────────────────
stage_finalize_download() {
  # map internal format names to file extensions
  win_ext="$win_fmt"
  [[ "$win_ext" == "png-indexed" || "$win_ext" == "png-grayscale" ]] && win_ext="png"
  win_ext="${win_ext%-transcode}"
  out="${OUTDIR}/${stem}.${win_ext}"

  # skip if already downloaded with expected size
  if [[ -f "$out" ]] && [[ "$_size" -gt 0 ]] 2>/dev/null; then
    local_size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)"
    if [[ "$local_size" -eq "$_size" ]]; then
      echo "   SKIP (already exists, ${_size} bytes): $out"
      (( OK++ )) || true
      _SKIP=1; return
    fi
  fi

  win_ext_upper="$(echo "$win_ext" | tr '[:lower:]' '[:upper:]')"
  echo "   BEST → ${win_ext_upper} ($(( _size / 1024 )) KB)"
  echo "   downloading → $out"

  # URLs flagged as needing browser TLS (Cloudflare challenge or Akamai Bot
  # Manager block) are fetched with curl_cffi instead of aria2c.
  if grep -qF "$win_url" "$CF_BYPASS_FILE" 2>/dev/null; then
    echo "   (browser-TLS bypass via curl_cffi)"
    if cffi_download "$win_url" "$out"; then
      (( OK++ )) || true
    else
      echo "   !! download failed (curl_cffi)" >&2
      (( FAIL++ )) || true
    fi
  else
    # Squarespace / PMC-Photon serve WebP transcodes for any Accept that contains
    # */* or webp; aria2c's default Accept does both. Force a no-webp Accept so we
    # actually receive the original format the probe pipeline picked.
    _aria_extra=()
    wants_original_accept "$win_url" && _aria_extra+=( --header="Accept: $SQUARESPACE_ACCEPT" )

    # Use --allow-overwrite=true and DROP -c (continue/resume) for the image
    # path. Resume is unsafe here: between two runs the probe pipeline can
    # pick a different winner URL (e.g. /medium/ first run, /original/ second),
    # and aria2c -c cannot detect that — it would keep the existing prefix and
    # only fetch the byte-range past local-size, splicing two different files
    # together (the GOAT cleat regression: 24 KB /medium/ files left behind a
    # 113 KB output that was 750x500 in the SOF marker but had the master's
    # Content-Length header). Reaching this point means the upstream skip
    # check already determined the file does not match Content-Length, so a
    # full re-fetch is what we want anyway. Mux/Vimeo paths still use -c
    # because their stream URLs are stable per-asset and resumes are valuable
    # for hundred-MB videos.
    # Cloudflare Polish bypass — apply a FRESH cache-buster per network phase.
    # The probe phase already warmed an entry with its own bust ID; reusing it
    # risks aria2c catching the Polish BGJ mid-rewrite. New bust = new cache
    # key = guaranteed MISS = origin bytes for the duration of the download.
    _download_url="$win_url"
    if grep -qxF "$win_url" "$CF_POLISH_FILE" 2>/dev/null; then
      _download_url="$(cf_polish_bust_url "$win_url")"
      echo "   (Cloudflare Polish bypass)"
    fi

    if aria2c --connect-timeout="$CURL_CONNECT_TIMEOUT" --allow-overwrite=true --auto-file-renaming=false \
        -x 16 -s 16 -k 1M --header="User-Agent: $UA" \
        ${_aria_extra[@]+"${_aria_extra[@]}"} \
        -o "$(basename "$out")" -d "$OUTDIR" "$_download_url" --quiet; then
      (( OK++ )) || true
    else
      echo "   !! download failed" >&2
      (( FAIL++ )) || true
    fi
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────────────
# process_url — run one URL through every stop on the pipeline. Stages share
# global state and signal "skip to the next URL" by setting _SKIP=1.
# ────────────────────────────────────────────────────────────────────────────
process_url() {
  url="$1"

  # Expand bare Vimeo IDs when --vimeo is active
  if $VIMEO_MODE && [[ "$url" =~ ^[0-9]{6,}$ ]]; then
    url="https://vimeo.com/${url}"
  fi

  (( TOTAL++ )) || true

  # reset per-URL pipeline state
  CANDIDATES=()
  BASELINE_FMT="unknown"
  BASELINE_CT="unknown"
  BASELINE_DIMS=""
  CLOUDINARY_BARE_ORIGIN=false

  stem="$(basename_from_url "$url")"
  [[ -n "$CUSTOM_FILENAME" ]] && stem="$CUSTOM_FILENAME"
  echo ""
  echo "── [$TOTAL] $url"

  _SKIP=0
  stage_fbsbx_media            ; (( _SKIP )) && return 0
  stage_apple_artwork          ; (( _SKIP )) && return 0
  stage_reddit_post            ; (( _SKIP )) && return 0
  stage_video_intercept        ; (( _SKIP )) && return 0
  stage_cdn_resolve_baseline
  stage_probe_formats
  stage_select_winner          ; (( _SKIP )) && return 0
  stage_finalize_download
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────
# Run the pipeline only when executed directly. When the file is *sourced*
# (e.g. by tests/run.sh), this guard is false, so every function above loads
# for inspection without arg-parsing, reading stdin, or downloading anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTDIR="$2"; shift 2 ;;
    -c|--cookies)      COOKIES="$2"; shift 2 ;;
    --vimeo)           VIMEO_MODE=true; shift ;;
    --force-download)  FORCE_DOWNLOAD=true; shift ;;
    --no-cdn)    NO_CDN=true; shift ;;
    --trust-cdn) TRUST_CDN=true; shift ;;
    --referer|--referrer)
      # the same normalization as input URLs: scheme supplied, CR/whitespace
      # stripped, //host form completed (a bare "https://" prefix mangled those)
      VIMEO_REFERER="$(normalize_url "$2")" || VIMEO_REFERER="$2"
      shift 2 ;;
    --filename)  CUSTOM_FILENAME="$2"; shift 2 ;;
    --format-discover) FORMAT_DISCOVER="$2"; shift 2 ;;
    -h|--help)   usage ;;
    -?*)         echo "ERROR: Unknown option: $1 (run with --help for usage)" >&2; exit 1 ;;
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

# drive the pipeline — one stop-by-stop pass per URL
while IFS= read -r url; do
  process_url "$url"
done < <(collect_urls)

# summary
[[ $TOTAL -eq 0 ]] && echo "!! nothing to do: no URL was read from the arguments/stdin (see the messages above)" >&2
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done. ${OK}/${TOTAL} downloaded, ${FAIL} failed."
echo " Output: ${OUTDIR}/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

fi  # end direct-execution guard