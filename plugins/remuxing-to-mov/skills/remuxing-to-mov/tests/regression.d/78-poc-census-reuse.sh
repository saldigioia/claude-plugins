#!/usr/bin/env bash
# 78-poc-census-reuse.sh — WO-1.15.3 Item 2 (1.15.2 leftover 5.4): the POC
# gate must not re-read what the census already read.
#
# Field-recorded cost: the gate's whole-file output trace_headers parse took
# ~20 of its 26m16s on the 23.68 GB artifact — while pf_trace_census had
# ALREADY paid a whole-file trace_headers pass over the SAME coded pictures on
# the source. The reuse license is copy-by-construction within the same run
# (pairfill's video is unconditionally -c copy), corroborated at sign-off by
# verify.sh gate (b) VCL identity — and it is MEASURED, not argued: the A/B
# below is the appendix result (2026-08-27, this bench) pinned as a
# relationship. A future non-copy path must NOT inherit the reuse; the
# direct-output extraction stays as the fallback arm (and as poc-gate.sh's
# default arm), and THIS A/B is the regression pin that the two arms agree.
#
# Relationship pins only (Gate 2): census-emitted idr,poc table byte-equal to
# the direct-output extraction; pf_poc_lattice verdict identical through both
# arms; SPS value equal from both captures. No bench literals.
#
# Standalone: bash tests/regression.d/78-poc-census-reuse.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$SC/lib-probe.sh"
. "$SC/lib-paff.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }
PF="$SC/pairfill-paff.sh"

echo "== 1. fixture: B-frame (type-0) mpegts, copied ts -> mov (the reuse license's shape) =="
ff -f lavfi -i testsrc2=r=25:s=320x240:d=2 -c:v libx264 -bf 3 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/poc0.ts" \
  || { echo "mint failed"; exit 2; }
ff -i "$WORK/poc0.ts" -map 0:v:0 -c copy "$WORK/poc0.mov" || { echo "copy failed"; exit 2; }

echo
echo "== 2. arm A: census side-file emission (same pass, zero extra reads) =="
eval "$(pf_trace_census "$WORK/poc0.ts" "$WORK/tbl.src" "$WORK/sps.src")"
[ "${PC_OK:-no}" = yes ] && ok "census PC_OK=yes on the source" || no "census PC_OK=$PC_OK"
[ -s "$WORK/tbl.src" ] && ok "census emitted a non-empty idr,poc table" || no "census idr,poc side file empty/missing"
[ -s "$WORK/sps.src" ] && ok "census emitted the SPS log2_max side file" || no "census SPS side file empty/missing"
[ "$(grep -c . "$WORK/tbl.src" || true)" = "${PC_PICS:-x}" ] \
  && ok "table rows == PC_PICS (every counted picture carried its lsb)" \
  || no "table rows $(grep -c . "$WORK/tbl.src") != PC_PICS=$PC_PICS"

echo
echo "== 3. arm B: direct-output extraction (the fallback arm, factored) =="
pf_poc_extract "$WORK/poc0.mov" "$WORK/tbl.mov" "$WORK/sps.mov" || no "pf_poc_extract returned nonzero"
[ -s "$WORK/tbl.mov" ] && ok "direct extraction emitted a non-empty table" || no "direct extraction table empty/missing"

echo
echo "== 4. the A/B: source census vs output extraction — byte-identical =="
if cmp -s "$WORK/tbl.src" "$WORK/tbl.mov"; then
  ok "idr,poc tables byte-identical across ts -> -c copy -> mov (the measured soundness claim)"
else
  no "tables differ (src $(grep -c . "$WORK/tbl.src") rows vs mov $(grep -c . "$WORK/tbl.mov") rows)"
fi
s_src=$(head -1 "$WORK/sps.src" 2>/dev/null); s_mov=$(head -1 "$WORK/sps.mov" 2>/dev/null)
{ [ -n "$s_src" ] && [ "$s_src" = "$s_mov" ]; } \
  && ok "SPS log2_max value equal from both captures ($s_src)" \
  || no "SPS captures disagree/empty (src='$s_src' mov='$s_mov')"

echo
echo "== 5. lattice verdict identical through both arms (and on-slot on the healthy copy) =="
ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$WORK/poc0.mov" 2>/dev/null | \
  awk -F, 'NF && $1!="N/A"{ print $1+0 }' > "$WORK/pts.mov"
[ "$(grep -c . "$WORK/pts.mov" || true)" = "$(grep -c . "$WORK/tbl.src" || true)" ] \
  && ok "output non-N/A PTS rows == table rows (the count guard's identity)" \
  || no "PTS rows $(grep -c . "$WORK/pts.mov") != table rows $(grep -c . "$WORK/tbl.src")"
MAXLSB=$((1 << (${s_src:-0} + 4)))
paste -d, "$WORK/tbl.src" "$WORK/pts.mov" > "$WORK/t_a.csv"
paste -d, "$WORK/tbl.mov" "$WORK/pts.mov" > "$WORK/t_b.csv"
eval "$(pf_poc_lattice "$WORK/t_a.csv" "$MAXLSB")"; a_on=$PL_ON; a_tot=$PL_TOTAL; a_off=$PL_OFF
eval "$(pf_poc_lattice "$WORK/t_b.csv" "$MAXLSB")"; b_on=$PL_ON; b_tot=$PL_TOTAL; b_off=$PL_OFF
{ [ "$a_on" = "$b_on" ] && [ "$a_tot" = "$b_tot" ] && [ "$a_off" = "$b_off" ]; } \
  && ok "verdicts identical through both arms ($a_on/$a_tot on-slot, off=$a_off)" \
  || no "arms disagree (census $a_on/$a_tot/$a_off vs direct $b_on/$b_tot/$b_off)"
[ "${a_off:-1}" = 0 ] && ok "healthy copy: every picture on its slot through the census arm" \
  || no "healthy copy off=$a_off through the census arm"

echo
echo "== 6. the shipping code path: pairfill's gate takes the census arm =="
psrc=$(cat "$PF")
has "$psrc" "pf_poc_extract" "pairfill keeps the direct-extraction fallback arm"
has "$psrc" "census" "pairfill's gate references the census reuse"
cat > "$WORK/scan_run2.csv" <<'CSV'
0,0
N/A,N/A
3600,3600
N/A,N/A
N/A,N/A
7200,7200
N/A,N/A
10800,10800
N/A,N/A
14400,14400
CSV
if pf_setts_probe 'if(lt(PTS\,-8000000000000000000)\,NEXT_PTS\,PTS)'; then
  o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" bash "$PF" "$WORK/poc0.ts" "$WORK/j.mov" --rate 50 2>&1); rc=$?
  has "$o" "census-pass reuse" "junction build announces the reuse arm"
  has "$o" "PP_POC_LATTICE on_slot=" "POC gate still emits its machine row"
  has "$o" " off=0" "reuse arm: every picture on its slot"
  { [ "$rc" -eq 0 ] && [ -f "$WORK/j.mov" ]; } \
    && ok "junction build blessed through the reuse arm (rc=0)" \
    || no "junction build rc=$rc through the reuse arm"
else
  echo "  (SKIP: this setts lacks NEXT_PTS — the end-to-end half needs a capable ffmpeg;"
  echo "   the arm A/B above is the load-bearing pin.)"
fi

echo
echo "== 7. TWO WRITERS OF \"POC PER PICTURE\", PINNED ON avcC (IV.1, Finding 8) =="
# The tree has two readers of each picture's declared display position:
#   * h264poc.Parser.parse_slice — Python, fast, used by Rungs 3-POC/3-DERIVE
#   * pf_poc_extract             — ffmpeg trace_headers, ~20 min on 24 GB, used
#                                  by the POC gate and verify gate (k)
# They are NOT interchangeable (the cost is load-bearing, lib-paff.sh) so they
# stay two, and Article IV.3 then requires them held in lockstep. Until 1.17.0
# they disagreed on the one thing that matters most here — CARRIAGE. On this
# very .mov the trace_headers arm read every picture and the Python arm read
# NONE, which is exactly how verify gate (k) came to judge an artifact its own
# BUILDER could not open. The sections above pin the two shell arms against
# each other; this pins the Python arm against them, on avcC.
E2E_PY=python3
E2E_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
if [ -x "$E2E_DATA/venv/bin/python" ] && "$E2E_DATA/venv/bin/python" -c 'import av' 2>/dev/null; then
  E2E_PY="$E2E_DATA/venv/bin/python"
fi
if "$E2E_PY" -c 'import av' 2>/dev/null; then
  "$E2E_PY" - "$SC" "$WORK/poc0.mov" > "$WORK/tbl.py" 2>"$WORK/py.err" <<'PYARM'
import sys
sys.path.insert(0, sys.argv[1])
import av, h264poc
c = av.open(sys.argv[2])
v = c.streams.video[0]
ex = bytes(getattr(v.codec_context, "extradata", b"") or b"")
par = h264poc.Parser(h264poc.avcc_length_size(ex))
ps = h264poc.avcc_param_sets(ex)
if ps:
    par.feed_parameter_sets(ps)
for pkt in c.demux(v):
    if pkt.size == 0:
        continue
    sh = par.parse_slice(bytes(pkt))
    if sh is None:
        print("unparsed")
    else:
        print("%d,%s" % (1 if sh["nal"] == 5 else 0,
                         "" if sh["poc_lsb"] is None else sh["poc_lsb"]))
c.close()
PYARM
  npy=$(grep -c . "$WORK/tbl.py" 2>/dev/null || true)
  nun=$(grep -c '^unparsed$' "$WORK/tbl.py" 2>/dev/null || true)
  { [ "${npy:-0}" -gt 0 ] && [ "${nun:-0}" -eq 0 ]; } \
    && ok "the Python arm parses all $npy picture(s) of the avcC .mov (0 unparsed)" \
    || { no "Python arm on avcC: $npy row(s), $nun unparsed"; sed 's/^/     /' "$WORK/py.err" | awk 'NR<=4'; }
  # the trace_headers table is "idr,poc,l2,src"; reduce it to the same two columns
  awk -F, '{ printf "%s,%s\n", $1, ($4=="lsb" ? $2 : "") }' "$WORK/tbl.mov" > "$WORK/tbl.mov2"
  if cmp -s "$WORK/tbl.py" "$WORK/tbl.mov2"; then
    ok "both writers agree picture-for-picture on (idr, pic_order_cnt_lsb) over avcC"
  else
    no "the two POC writers disagree on the avcC artifact"
    diff "$WORK/tbl.mov2" "$WORK/tbl.py" 2>/dev/null | awk 'NR<=6' | sed 's/^/     /'
  fi
else
  echo "  (SKIP: no interpreter on this bench has PyAV — the Python arm cannot be read here)"
fi

echo
echo "== 8. the cost model is recorded (knobs.md) =="
ksrc=$(cat "$TESTS/../references/knobs.md")
has "$ksrc" "POC" "knobs.md records the POC-gate cost model"
has "$ksrc" "census" "knobs.md names the census reuse"

echo
echo "poc-census-reuse: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
