#!/usr/bin/env bash
# 114-capability-one-authority.sh — two readers, one answer about the same
# stream (Constitution IV.1 one writer per fact / IV.2 ask the authority).
#
# WHY (measured 2026-08-29, on one x264 -bf 0 mint):
#
#   pf_poc_capability (shell head probe) ->  PCAP_OK=no  PCAP_WHY=poc_type
#   h264poc.Parser.capability()          ->  (True, 'poc_type=2 (display order
#                                             equals decode order by spec)')
#
# The module that would do the work said it could; the shell probe modelling
# that capability said it could not; and `pairfill-paff.sh` refused at
# pre-flight, exit 3, nothing built, on the SHELL verdict. The probe was right
# when it was written — nothing then could read a `pic_order_cnt_type 2`
# stream. 1.16.4 made those positions derivable everywhere else and left this
# one model behind, which is how a stale model always fails: quietly, in the
# direction of refusing work that now succeeds.
#
# THE BAR DOES NOT MOVE. `pic_order_cnt_type 1` is still unsupported by both
# readers, still PCAP_WHY=poc_type, still exit 3 with nothing written. What
# changes is that a stream whose display order IS derivable is no longer
# refused for not carrying a syntax element it is not supposed to carry.
#
# Standalone: bash tests/regression.d/114-capability-one-authority.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 absent"; echo "capability-one-authority: 0 passed, 0 failed"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$SC/lib-paff.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

# a canned head-trace log carrying one SPS of the named pic_order_cnt_type and
# three coded pictures (no media: the shell probe reads text)
canned () {  # canned TYPE OUT
  { printf '[trace_headers @ 0x1] 41          pic_order_cnt_type                                        011 = %d\n' "$1"
    [ "$1" = 0 ] && printf '[trace_headers @ 0x1] 42          log2_max_pic_order_cnt_lsb_minus4                         011 = 2\n'
    printf '[trace_headers @ 0x1] 7           nal_unit_type                                           00101 = 5\n'
    for i in 1 2 3; do
      printf '[trace_headers @ 0x1] 8           first_mb_in_slice                                           1 = 0\n'
      [ "$1" = 0 ] && printf '[trace_headers @ 0x1] 5           pic_order_cnt_lsb                                  0000000%d00 = %d\n' "$i" "$((i * 4))"
    done
  } > "$2"
  return 0
}

echo "== 1. the two readers agree, poc_type by poc_type =="
for t in 0 1 2; do
  canned "$t" "$WORK/head_$t.log"
  eval "$(pf_poc_capability "$WORK/head_$t.log")"
  shell_ok="${PCAP_OK:-unset}"; shell_why="${PCAP_WHY:-unset}"
  mod=$(python3 - "$SC" "$t" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from h264poc import Parser

class W:
    def __init__(self): self.bits = []
    def u(self, n, v):
        for i in range(n - 1, -1, -1): self.bits.append((v >> i) & 1)
    def ue(self, v):
        v += 1; n = v.bit_length(); self.u(n - 1, 0); self.u(n, v)
    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)
    def bytes(self):
        pad = self.bits + [1] + [0] * ((8 - (len(self.bits) + 1) % 8) % 8)
        b = bytearray()
        for i in range(0, len(pad), 8):
            byte = 0
            for bit in pad[i:i+8]: byte = (byte << 1) | bit
            b.append(byte)
        return bytes(b)

def sps(poc_type):
    w = W()
    w.u(8, 100); w.u(8, 0); w.u(8, 40)
    w.ue(0)              # sps_id
    w.ue(1); w.ue(0); w.ue(0)
    w.u(1, 0); w.u(1, 0)
    w.ue(4)              # log2_max_frame_num_minus4
    w.ue(poc_type)
    if poc_type == 0:
        w.ue(2)          # log2_max_pic_order_cnt_lsb_minus4
    elif poc_type == 1:
        w.u(1, 0)        # delta_pic_order_always_zero_flag
        w.se(0); w.se(0) # offset_for_non_ref_pic, offset_for_top_to_bottom_field
        w.ue(1); w.se(2) # num_ref_frames_in_pic_order_cnt_cycle + its one entry
    w.ue(4); w.u(1, 0)
    w.ue(119); w.ue(33); w.u(1, 1)
    return b"\x00\x00\x01\x67" + w.bytes()

p = Parser()
p.feed_parameter_sets(sps(int(sys.argv[2])))
capable, why = p.capability()
print("yes" if capable else "no")
PY
)
  case "$t" in
    0|2) want=yes ;;
    *)   want=no  ;;
  esac
  [ "$mod" = "$want" ] && ok "poc_type $t: the module answers $mod" || no "poc_type $t: module says $mod, want $want"
  [ "$shell_ok" = "$mod" ] \
    && ok "…and the shell probe agrees ($shell_ok)" \
    || no "poc_type $t: shell says $shell_ok, the module says $mod — two writers, one fact"
  if [ "$t" = 1 ]; then
    [ "$shell_why" = poc_type ] && ok "…and poc_type 1 is refused BY NAME (why=$shell_why)" \
      || no "poc_type 1: why=$shell_why, want poc_type"
  fi
done

echo
echo "== 2. on real media: a type-2 capture reads as capable, and says how =="
ff -f lavfi -i "testsrc2=s=160x120:r=25" -t 2 -c:v libx264 -bf 0 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/t2.ts"
ffmpeg -nostdin -hide_banner -nostats -i "$WORK/t2.ts" -map 0:v:0 -c copy -frames:v 40 \
  -bsf:v trace_headers -f null - >/dev/null 2>"$WORK/real.log"
eval "$(pf_poc_capability "$WORK/real.log")"
[ "${PCAP_POC_TYPE:--1}" = 2 ] && ok "the mint really is pic_order_cnt_type 2" \
  || { echo "  SKIP: this libx264 minted poc_type ${PCAP_POC_TYPE:--1}, not 2"; echo "capability-one-authority: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; exit $?; }
[ "${PCAP_OK:-no}" = yes ] && ok "PCAP_OK=yes on a stream whose order is derivable" || no "PCAP_OK=${PCAP_OK:-unset}, want yes"
[ "${PCAP_WHY:-}" = t2_derived ] && ok "…and the reason is named, not blank (why=t2_derived)" || no "PCAP_WHY=${PCAP_WHY:-unset}, want t2_derived"
[ "${PCAP_LSB_ROWS:-9}" = 0 ] && ok "…with zero lsb rows, which is what type 2 is supposed to carry" || no "PCAP_LSB_ROWS=${PCAP_LSB_ROWS:-unset}, want 0"

echo
echo "== 3. the builder no longer refuses it at pre-flight for that reason =="
# one 2-run junction in an otherwise strictly-alternating scan, and
# PF_SETTS_OK=yes, so the run reaches the capability pre-flight on any bench
# (without them pairfill exits at an EARLIER precondition and the row under
# test is never printed — which made an rc=3 pin pass for the wrong reason).
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
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes \
    bash "$SC/pairfill-paff.sh" "$WORK/t2.ts" "$WORK/t2.mov" --rate 50 2>&1); rc=$?
has "$o" "PP_POC_CAPABILITY ok=yes why=t2_derived" "the machine row carries the capable verdict"
hasnt "$o" "the POC-lattice gate cannot be evaluated" "no refusal claims the lattice cannot be evaluated"
case "$o" in
  *"JUNCTION MODEL REFUSED"*"pic_order_cnt"*) no "still refused at pre-flight on the POC capability" ;;
  *"JUNCTION MODEL REFUSED"*) ok "(refused for a different, still-true reason — its own jurisdiction)" ;;
  *) ok "the source was not refused on the POC capability" ;;
esac

echo
echo "== 4. the bar did not move: poc_type 1 still refuses, nothing written =="
canned 1 "$WORK/head_t1.log"
o=$(PP_SCAN_FILE="$WORK/scan_run2.csv" PF_SETTS_OK=yes PF_HEAD_TRACE_FILE="$WORK/head_t1.log" \
    bash "$SC/pairfill-paff.sh" "$WORK/t2.ts" "$WORK/nope.mov" --rate 50 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "a pic_order_cnt_type 1 source -> exit 3 (pre-flight refusal)" || no "type-1 source rc=$rc, want 3"
# and it is THIS refusal, not an earlier one that happens to share the rc
has "$o" "JUNCTION MODEL REFUSED: pic_order_cnt_type=1" "…and the refusal is the POC-capability one, by name"
has "$o" "PP_POC_CAPABILITY ok=no why=poc_type" "…with the machine row saying why"
[ ! -e "$WORK/nope.mov" ] && ok "…and nothing was written" || no "the refusal left bytes at the output path"

echo
echo "== 5. diagnose reports the same fact as everyone else =="
d=$(bash "$SC/diagnose.sh" "$WORK/t2.ts" 2>&1)
has "$d" "DIAG_POC_CAPABILITY ok=yes" "diagnose agrees the capture is POC-judgeable"
hasnt "$d" "POC capability: NO" "…and prints no capability refusal for it"

echo
echo "capability-one-authority: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
