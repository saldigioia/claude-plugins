#!/usr/bin/env bash
# 98-stamp-derive-e2e.sh — WO-1.15.20 S2 end to end: stamp the isolated
# unstamped packets from their pair-mates, then derive, then bless — on real
# files, through the real driver, with every output gate armed.
#
# THE FIXTURES (tests/make-fixtures.sh, minted by PES-header surgery because no
# muxer will write this class — libavformat refuses a data-bearing video packet
# with no PTS, measured -22 on mpegts and matroska both):
#   sparse-nopts.ts   reordered field-pair timeline, PTS-complete except three
#                     stride-2 clusters whose members each have a timestamped
#                     pair-mate. The 2024-VMA class.
#   sparse-orphan.ts  the same plus one ADJACENT unstamped pair — each is the
#                     other's mate, so neither has evidence. The control.
#
# The counts are pinned as RELATIONSHIPS: the test measures how many packets
# the fixture actually left unstamped and requires the census to equal that.
# Nothing here depends on the number seven.
#
# Standalone: bash tests/regression.d/98-stamp-derive-e2e.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

for f in sparse-nopts.ts sparse-orphan.ts; do
  [ -s "$FIX/$f" ] || { echo "SKIP: $f absent — run: bash tests/make-fixtures.sh $f"; echo "stamp-derive-e2e: 0 passed, 0 failed"; exit 0; }
done
# the rung's only optional dependency; an absent venv is an announced skip, and
# the harness counts it (1.15.8 E3) rather than reporting a silent green.
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
if ! [ -x "$DATA/venv/bin/python" ] || ! "$DATA/venv/bin/python" -c 'import av' 2>/dev/null; then
  echo "SKIP: PyAV venv absent — Rung 3-DERIVE cannot run end to end here"
  echo "      bootstrap: python3 -m venv \"$DATA/venv\" && \"$DATA/venv/bin/pip\" install av"
  echo "stamp-derive-e2e: 0 passed, 0 failed"; exit 0
fi

nopts_of () { ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$1" 2>/dev/null |
                awk -F, '$1=="N/A"||$1==""{n++} END{print n+0}'; }
pkts_of ()  { ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$1" 2>/dev/null | grep -c .; }

MINTED=$(nopts_of "$FIX/sparse-nopts.ts")
SRCPK=$(pkts_of "$FIX/sparse-nopts.ts")
echo "== 1. the fixture is the class (measured, not assumed) =="
[ "$MINTED" -gt 0 ] && ok "the source has $MINTED unstamped video packet(s)" \
                     || no "the source has no unstamped packets — wrong fixture"
awk "BEGIN{exit !($MINTED/$SRCPK <= 0.01 && $MINTED/$SRCPK > 0)}" \
  && ok "…a fraction inside the sparse bound, and nonzero" \
  || no "fixture fraction $MINTED/$SRCPK is not the sparse class"

echo
echo "== 2. the rung: stamp, derive, pass every gate, bless =="
o=$(bash "$SC/derive-dts.sh" "$FIX/sparse-nopts.ts" "$WORK/out.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "derive-dts.sh exits 0 (blessed)" || no "rc=$rc, want 0"
[ -s "$WORK/out.mov" ] && ok "the artifact landed under its real name" || no "no output at \$WORK/out.mov"
has "$o" "sparse-unstamped pre-pass" "the pre-pass announces itself"
has "$o" "stamped=$MINTED" "the census reports stamped=$MINTED — equal to what the fixture minted"
has "$o" "method=pair-mate" "…and names the evidence the values came from"
has "$o" "verdict=ok" "the DERIVE_DTS machine row reads verdict=ok"
n=$(printf '%s\n' "$o" | grep -c 'DERIVE_STAMP idx=')
[ "$n" -eq "$MINTED" ] && ok "one DERIVE_STAMP provenance row per reconstruction ($n)" \
                       || no "$n stamp rows for $MINTED reconstructions"
for g in "gate 1/4" "gate 2/4" "gate 3/4" "gate 4/4"; do
  has "$o" "$g" "output $g ran"
done
hasnt "$o" "GATE FAILED" "no output gate failed"

echo
echo "== 3. the output presents the whole, repaired timeline =="
OUTPK=$(pkts_of "$WORK/out.mov")
[ "$OUTPK" -eq "$SRCPK" ] && ok "every coded picture survived ($OUTPK == $SRCPK)" \
                          || no "packet count $OUTPK != source $SRCPK"
[ "$(nopts_of "$WORK/out.mov")" -eq 0 ] && ok "the output has NO unstamped packets left" \
                                        || no "the output still carries unstamped packets"
# the true property of a repaired field timeline: the sorted PTS column is a
# single arithmetic progression. A wrong fill breaks it in two places at once
# (a gap where the value belongs and a collision where it landed), so this is
# an independent check on the reconstructed VALUES, not just their count.
prog=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$WORK/out.mov" 2>/dev/null |
  tr -d ',' | LC_ALL=C sort -n | awk 'NR==1{p=$1;next}{d=$1-p; c[d]++; p=$1}
    END{n=0; for(k in c) n++; printf "%d %s", n, (n==1?"uniform":"broken")}')
case "$prog" in "1 uniform") ok "the output PTS column is one uniform progression (no gap, no collision)";;
  *) no "the output PTS column has $prog spacing(s) — a reconstruction is wrong";; esac

echo
echo "== 4. the essence was never touched =="
vcl () { local b=""
  [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1" 2>/dev/null)" = true ] && b="h264_mp4toannexb,"
  ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c:v copy -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null; }
sv=$(vcl "$FIX/sparse-nopts.ts"); ov=$(vcl "$WORK/out.mov")
{ [ -n "$sv" ] && [ "$sv" = "$ov" ]; } && ok "VCL payload identical — the stamps are container metadata only" \
                                       || no "VCL differs (src=$sv out=$ov)"

echo
echo "== 5. verify.sh signs the artifact off =="
v=$(bash "$SC/verify.sh" "$FIX/sparse-nopts.ts" "$WORK/out.mov" 2>&1) || true
# OK and REVIEW BOTH exit 0 — pin the VERDICT LINE, never the rc
case "$v" in *">> OK"*) ok "verify verdict: OK";;
  *">> REVIEW"*) ok "verify verdict: REVIEW (a verdict, not a failure)";;
  *) no "verify produced neither an OK nor a REVIEW verdict";; esac
hasnt "$v" ">> FAIL" "verify does not FAIL the repaired artifact"
# the timeline gate is the one this round exists to satisfy: it must be clean,
# whatever the synthetic fixture's decode noise does to the overall verdict
hasnt "$v" "backward DTS" "…and the derived timeline shows no backward DTS"

echo
echo "== 6. the orphan control: refuse the WHOLE file, write nothing =="
ORPH=$(nopts_of "$FIX/sparse-orphan.ts")
o=$(bash "$SC/derive-dts.sh" "$FIX/sparse-orphan.ts" "$WORK/orph.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "an orphaned hole refuses with exit 3" || no "orphan rc=$rc, want 3"
ls "$WORK"/orph.mov* >/dev/null 2>&1 && no "the refusal still wrote something" || ok "nothing written, under any name"
has "$o" "no timestamped pair-mate" "the refusal says what was missing"
has "$o" "Coded positions:" "…and names the positions"
has "$o" "360, 361" "…which are the adjacent pair the fixture minted"
hasnt "$o" "stamped=" "no census is emitted for a file that was never built"
# and the refusal is about the ORPHANS, not the seven it could have filled
awk "BEGIN{exit !($ORPH > $MINTED)}" && ok "the control has more holes than the positive fixture ($ORPH > $MINTED)" \
                                     || no "the two fixtures are not distinguishable"

echo
echo "stamp-derive-e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
