#!/usr/bin/env bash
# batch.sh — run auto.sh over many inputs, write a provenance sidecar per output,
# and a run report. Idempotent: a re-run skips inputs already verified OK whose
# source is unchanged. NEVER deletes sources; outputs are written atomically by
# the sub-scripts; sidecars are written atomically here.
#
# Usage: scripts/batch.sh INPUT... [--out DIR] [-- AUTO_OPTS...]
#   INPUT...     files and/or directories (dirs are scanned for capture exts)
#   --out DIR    write outputs + sidecars here (default: beside each source)
#   -- AUTO_OPTS everything after `--` is passed to auto.sh (e.g. --full --all-audio)
#
# Sidecar (<output>.provenance.kv) records source id+hash, rung, ffmpeg version,
# verdict, and timestamp — so a file's origin is auditable and re-verifiable.
#
# AUDIO POLICY: batch drives auto.sh, the LADDER (single-track audio, no
# --signaling drift check) — not mov.sh, the deliverable builder. For the
# dual-track PCM-access deliverable per file, run mov.sh on each instead;
# `-- --audio pcm` here only changes the codec, not the track layout.
#
# THROUGHPUT (QTFF audit 5-5a): every output is written with +faststart, which
# costs a second full-file pass (~2x write I/O per file — moov is written last,
# then relocated). On multi-GB masters over external SSDs that second pass
# dominates batch wall time; faststart is an access-copy need, not a
# shelved-master need (see container-internals.md, "faststart's cost").
# Exit: 0 if nothing FAILed, 1 otherwise. A REFUSED (auto.sh exit 11: the
# unroutable-codec pre-flight — VC-1/VP9/AV1/Dolby E, shared gate since the
# 1.11 fix round — or a child's own refusal like resync's layout guard) is the
# gate doing its job — reported for attention, never a batch failure.
set -eu
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
. "$SELF_DIR/lib-probe.sh"  # FF_INPUT_OPTS: raised probe window on the provenance hash read
OUTDIR=""; AUTO_OPTS=(); INPUTS=()
while [ $# -gt 0 ]; do case "$1" in
  --out) OUTDIR="${2:?--out needs a dir}"; shift 2;;
  --) shift; while [ $# -gt 0 ]; do AUTO_OPTS+=("$1"); shift; done;;
  *) INPUTS+=("$1"); shift;;
esac; done
[ "${#INPUTS[@]}" -gt 0 ] || { echo "usage: batch.sh INPUT... [--out DIR] [-- AUTO_OPTS...]" >&2; exit 2; }
[ -z "$OUTDIR" ] || mkdir -p "$OUTDIR"

ffver=$(ffmpeg -version 2>/dev/null | head -1 | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1 || echo "?")
EXTS="ts mpg mpeg vob mkv mov mp4 m2ts mts m4v"

# expand inputs (dirs -> matching files); literal-glob safe (test -f filters non-matches)
files=()
for inp in "${INPUTS[@]}"; do
  if [ -d "$inp" ]; then
    for e in $EXTS; do for f in "$inp"/*."$e"; do [ -f "$f" ] && files+=("$f"); done; done
  elif [ -f "$inp" ]; then files+=("$inp")
  else echo "skip (not found): $inp" >&2; fi
done
[ "${#files[@]}" -gt 0 ] || { echo "no input files matched" >&2; exit 2; }

src_id () { local f="$1" sz mt
  sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  printf '%s:%s' "$sz" "$mt"; }
kvget () { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true; }

okc=0; revc=0; refc=0; failc=0; skipc=0; attention=()
for src in "${files[@]}"; do
  base=$(basename "$src"); stem=${base%.*}
  if [ -n "$OUTDIR" ]; then out="$OUTDIR/$stem.mov"; else out="$(dirname "$src")/$stem.mov"; fi
  srcabs="$(cd "$(dirname "$src")" && pwd)/$base"
  outabs="$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")"
  [ "$srcabs" = "$outabs" ] && out="${out%.mov}.remux.mov"     # never write onto the source
  side="$out.provenance.kv"; id=$(src_id "$src")
  if [ -f "$side" ] && [ "$(kvget "$side" PROV_SRC_ID)" = "$id" ] && [ "$(kvget "$side" PROV_VERDICT)" = OK ]; then
    echo "skip (already OK, unchanged): $src"; skipc=$((skipc+1)); continue
  fi
  echo "==== $src -> $out ===="
  set +e; o=$(bash "$SELF_DIR/auto.sh" "$src" "$out" ${AUTO_OPTS[@]+"${AUTO_OPTS[@]}"} </dev/null 2>&1); arc=$?; set -e
  echo "$o" | sed 's/^/  /'
  # Verdict is auto.sh's EXIT CODE (the contract: 0=OK, 10=REVIEW, 11=REFUSED,
  # else FAIL) — not a fragile text grep. AUTO_SUMMARY is parsed only for the
  # cosmetic rung. REFUSED is a pre-flight gate doing its job (1.11: the
  # unroutable-codec refusal, or a child's own — e.g. resync's layout guard;
  # the backhaul gate advises/warns, never refuses) — the source is unchanged,
  # listed for attention but never a batch failure.
  case "$arc" in 0) verd=OK;; 10) verd=REVIEW;; 11) verd=REFUSED;; *) verd=FAIL;; esac
  summ=$(printf '%s\n' "$o" | grep -E '^AUTO_SUMMARY ' | tail -1 || true)
  # [A-Za-z0-9] is load-bearing (1.11 fix round): the repair rungs are UPPERCASE
  # (P pair-fill, S resync) and a lowercase-only class matched neither — the
  # capture came back empty and the sidecar recorded PROV_RUNG=none for exactly
  # the two rungs whose provenance matters most. The greedy '.*rung=' correctly
  # targets the LAST rung= field (best_rung= sits before it by contract).
  rung=$(printf '%s' "$summ" | sed -n 's/.*rung=\([A-Za-z0-9]*\).*/\1/p'); rung=${rung:-none}
  vhash=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$src" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | sed -n 's/.*MD5=//p' | head -1 || true)
  { echo "PROV_SOURCE=$src"; echo "PROV_OUTPUT=$out"; echo "PROV_SRC_ID=$id"
    echo "PROV_SRC_VHASH=${vhash:-na}"; echo "PROV_RUNG=$rung"; echo "PROV_VERDICT=$verd"
    echo "PROV_FFMPEG=$ffver"; echo "PROV_WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$side.part" && mv -f "$side.part" "$side"
  case "$verd" in
    OK)      okc=$((okc+1));;
    REVIEW)  revc=$((revc+1)); attention+=("REVIEW  $src");;
    REFUSED) refc=$((refc+1)); attention+=("REFUSED $src  (nothing built, source unchanged — the refusal above names the routes)");;
    *)       failc=$((failc+1)); attention+=("FAIL    $src");;
  esac
done

echo
echo "==== batch report ===="
echo "  OK=$okc  REVIEW=$revc  REFUSED=$refc  FAIL=$failc  skipped=$skipc  (ffmpeg $ffver)"
[ "${#attention[@]}" -eq 0 ] || { echo "  needs attention:"; printf '   %s\n' "${attention[@]}"; }
[ "$failc" -eq 0 ]
