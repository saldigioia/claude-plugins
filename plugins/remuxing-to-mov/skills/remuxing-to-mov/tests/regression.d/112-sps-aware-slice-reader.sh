#!/usr/bin/env bash
# 112-sps-aware-slice-reader.sh — the slice-header reader takes its field
# widths from the ACTIVE SPS, never from a constant.
#
# WHY, and it is a measured near-miss in this plugin's own history. h264poc.py
# was ported from a workshop tool that hardcoded one capture's SPS:
#
#     FRAME_NUM_BITS = 8      POC_LSB_BITS = 8      FRAME_MBS_ONLY = 0
#
# Those were right for most of that capture and wrong for part of it. Measured
# 2026-08-29 on feed.ts: one SPS in the file declares
# log2_max_frame_num_minus4=0 (frame_num is FOUR bits) and
# log2_max_pic_order_cnt_lsb_minus4=2 (poc_lsb is SIX). Reading eight bits
# where four exist consumes four extra, so frame_num comes back as
# true*16 + four stray bits — the workshop's cache reads 32, 48, 16 where the
# true values are 2, 3, 1 — and every field AFTER it is read from the wrong bit
# offset, manufacturing field_pic_flag=1 on 17 frame pictures.
#
# That is how a parser produces a confident, plausible, wrong answer: not by
# failing, but by reading the right bits in the wrong place. The plugin's own
# census (ffmpeg's CBS) and h264poc.py agree with each other and disagree with
# the hardcoded parser on exactly those 17 — which is what a correct reader
# looks like from the outside.
#
# THE FIXTURE IS A SYNTHETIC BITSTREAM, built here, so this needs no media and
# no external capture: an SPS whose widths are deliberately NOT the common
# ones, and a slice whose true values a constant-width reader cannot recover.
#
# Standalone: bash tests/regression.d/112-sps-aware-slice-reader.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v python3 >/dev/null || { echo "SKIP: python3 absent"; echo "sps-aware-slice-reader: 0 passed, 0 failed"; exit 0; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

out=$(python3 - "$SC" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import h264poc

class W:
    """Minimal RBSP bit writer — enough to mint an SPS, a PPS and a slice."""
    def __init__(self): self.bits = []
    def u(self, n, v):
        for i in range(n - 1, -1, -1): self.bits.append((v >> i) & 1)
    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0); self.u(n, v)
    def bytes(self):
        b = bytearray()
        pad = self.bits + [1] + [0] * ((8 - (len(self.bits) + 1) % 8) % 8)
        for i in range(0, len(pad), 8):
            byte = 0
            for bit in pad[i:i+8]: byte = (byte << 1) | bit
            b.append(byte)
        return bytes(b)

def sps(log2_fn_minus4, log2_poc_minus4, frame_mbs_only):
    w = W()
    w.u(8, 100)          # profile_idc (a scaling-list profile)
    w.u(8, 0)            # constraint flags + reserved
    w.u(8, 40)           # level_idc
    w.ue(0)              # seq_parameter_set_id
    w.ue(1)              # chroma_format_idc 4:2:0
    w.ue(0); w.ue(0)     # bit_depth_luma/chroma minus8
    w.u(1, 0)            # qpprime_y_zero_transform_bypass
    w.u(1, 0)            # seq_scaling_matrix_present
    w.ue(log2_fn_minus4)
    w.ue(0)              # pic_order_cnt_type = 0
    w.ue(log2_poc_minus4)
    w.ue(4)              # max_num_ref_frames
    w.u(1, 0)            # gaps_in_frame_num_value_allowed
    w.ue(119); w.ue(33)  # width/height in MBs
    w.u(1, frame_mbs_only)
    if not frame_mbs_only: w.u(1, 0)   # mb_adaptive_frame_field_flag
    return b"\x00\x00\x01\x67" + w.bytes()

def pps():
    w = W()
    w.ue(0); w.ue(0)     # pps_id, sps_id
    w.u(1, 1)            # entropy_coding_mode_flag
    w.u(1, 0)            # bottom_field_pic_order_in_frame_present_flag
    return b"\x00\x00\x01\x68" + w.bytes()

def slice_nal(frame_num, fn_bits, field, bottom, poc_lsb, poc_bits,
              has_field_flag=True):
    """has_field_flag mirrors the SPS: a frame_mbs_only_flag=1 stream carries NO
    field_pic_flag bit at all. Writing one anyway shifts every later field by
    one bit and the fixture, not the reader, is then the thing under test."""
    w = W()
    w.ue(0)              # first_mb_in_slice
    w.ue(5)              # slice_type (P)
    w.ue(0)              # pic_parameter_set_id
    w.u(fn_bits, frame_num)
    if has_field_flag:
        w.u(1, field)
        if field: w.u(1, bottom)
    w.u(poc_bits, poc_lsb)
    return b"\x00\x00\x01\x41" + w.bytes()

# THE UNUSUAL SPS: frame_num 4 bits, poc_lsb 6 bits — the shape that appears in
# feed.ts at every program change, and the shape a constant-width reader gets
# wrong. TRUE values below are deliberately small so a 8-bit misread produces
# the *16 signature the workshop's cache shows.
TRUE_FN, TRUE_POC = 3, 41
au = sps(0, 2, 0) + pps() + slice_nal(TRUE_FN, 4, 1, 1, TRUE_POC, 6)

par = h264poc.Parser()
s = par.parse_slice(au)
print("PARSED=%s" % ("none" if s is None else "yes"))
if s is None:
    raise SystemExit
print("FRAME_NUM=%d" % s["frame_num"])
print("FIELD_PIC=%d" % s["field_pic"])
print("BOTTOM=%d" % s["bottom"])
print("POC_LSB=%d" % s["poc_lsb"])
print("MAX_POC_LSB=%d" % s["max_poc_lsb"])
sp = list(par.sps.values())[0]
print("SPS_LOG2_FN=%d" % sp["log2_max_frame_num"])
print("SPS_LOG2_POC=%d" % sp["log2_max_poc_lsb"])
# what a HARDCODED 8-bit reader would have produced from these very bits:
# it consumes 4 extra bits of frame_num, so the value scales by 16
print("MISREAD_FN_WOULD_BE=%d" % (TRUE_FN * 16))
print("TRUE_FN=%d" % TRUE_FN)
print("TRUE_POC=%d" % TRUE_POC)

# CONTROL: the ordinary SPS (8-bit frame_num, 8-bit poc_lsb) must still parse
au2 = sps(4, 4, 0) + pps() + slice_nal(200, 8, 1, 0, 250, 8)
par2 = h264poc.Parser()
s2 = par2.parse_slice(au2)
print("CTRL_FRAME_NUM=%d" % (-1 if s2 is None else s2["frame_num"]))
print("CTRL_POC_LSB=%d" % (-1 if s2 is None else s2["poc_lsb"]))
print("CTRL_MAX_POC_LSB=%d" % (-1 if s2 is None else s2["max_poc_lsb"]))

# CONTROL: a progressive SPS emits NO field_pic_flag, and the reader must not
# invent one by reading the next bit
au3 = sps(4, 4, 1) + pps() + slice_nal(7, 8, 0, 0, 33, 8, has_field_flag=False)
par3 = h264poc.Parser()
s3 = par3.parse_slice(au3)
print("PROG_FIELD_PIC=%d" % (-1 if s3 is None else s3["field_pic"]))
print("PROG_FRAME_NUM=%d" % (-1 if s3 is None else s3["frame_num"]))
print("PROG_POC_LSB=%d" % (-1 if s3 is None else s3["poc_lsb"]))

# THE avcC TWIN (1.17.0). Everything above is an ANNEX-B bitstream, and until
# 1.17.0 that was the only carriage this reader understood — so a suite that
# minted only Annex-B could pin every bit-width in the SPS and still miss that
# the reader was 100 % blind to MKV and MOV. The same access units, re-carried
# as length-prefixed avcC with the parameter sets moved into an
# AVCDecoderConfigurationRecord, must yield the SAME values.
def to_avcc(au, nls=4):
    """Split an Annex-B access unit and re-emit its NALs length-prefixed."""
    parts, i = [], 0
    while True:
        j = au.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        st = j + 3
        k = au.find(b"\x00\x00\x01", st)
        end = len(au) if k < 0 else (k - 1 if au[k - 1:k] == b"\x00" else k)
        parts.append(au[st:end])
        i = st
    return b"".join(len(p).to_bytes(nls, "big") + p for p in parts), parts

def avcc_extradata(sps_nal, pps_nal, nls=4):
    return (bytes([1, sps_nal[1], sps_nal[2], sps_nal[3], 0xFC | (nls - 1), 0xE1])
            + len(sps_nal).to_bytes(2, "big") + sps_nal
            + b"\x01" + len(pps_nal).to_bytes(2, "big") + pps_nal)

_buf, _nals = to_avcc(au)                       # au = the UNUSUAL-SPS access unit
_sps_nal, _pps_nal, _slice_nal = _nals[0], _nals[1], _nals[2]
_extra = avcc_extradata(_sps_nal, _pps_nal)
print("AVCC_NLS=%d" % h264poc.avcc_length_size(_extra))
print("AVCC_PS_NALS=%d" % sum(1 for _t, _r, _o in
                              h264poc.iter_nals(h264poc.avcc_param_sets(_extra))))
# the realistic shape: parameter sets in extradata, ONLY the slice in the packet
par4 = h264poc.Parser(h264poc.avcc_length_size(_extra))
par4.feed_parameter_sets(h264poc.avcc_param_sets(_extra))
s4 = par4.parse_slice(len(_slice_nal).to_bytes(4, "big") + _slice_nal)
print("AVCC_FRAME_NUM=%d" % (-1 if s4 is None else s4["frame_num"]))
print("AVCC_POC_LSB=%d" % (-1 if s4 is None else s4["poc_lsb"]))
print("AVCC_FIELD_PIC=%d" % (-1 if s4 is None else s4["field_pic"]))
print("AVCC_BOTTOM=%d" % (-1 if s4 is None else s4["bottom"]))
print("AVCC_MAX_POC_LSB=%d" % (-1 if s4 is None else s4["max_poc_lsb"]))
# and the in-band shape: every NAL in one length-prefixed buffer, no extradata
par5 = h264poc.Parser(4)
s5 = par5.parse_slice(_buf)
print("AVCC_INBAND_FRAME_NUM=%d" % (-1 if s5 is None else s5["frame_num"]))
print("AVCC_INBAND_POC_LSB=%d" % (-1 if s5 is None else s5["poc_lsb"]))
PY
) || { echo "  the reader raised on a valid synthetic bitstream"; echo "$out" | tail -5; echo "sps-aware-slice-reader: 0 passed, 1 failed"; exit 1; }

get () { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

echo "== 1. the SPS is READ, not assumed =="
[ "$(get PARSED)" = yes ] && ok "the synthetic access unit parses" || { no "the reader returned none"; printf '%s\n' "$out" | head -4; }
[ "$(get SPS_LOG2_FN)" = 4 ]  && ok "frame_num width taken from the SPS (4 bits, not the common 8)" || no "SPS_LOG2_FN=$(get SPS_LOG2_FN), want 4"
[ "$(get SPS_LOG2_POC)" = 6 ] && ok "poc_lsb width taken from the SPS (6 bits, not the common 8)" || no "SPS_LOG2_POC=$(get SPS_LOG2_POC), want 6"
[ "$(get MAX_POC_LSB)" = 64 ] && ok "MaxPicOrderCntLsb derives from that width (64)" || no "MAX_POC_LSB=$(get MAX_POC_LSB), want 64"

echo
echo "== 2. the values come back TRUE, not scaled by the misread =="
[ "$(get FRAME_NUM)" = "$(get TRUE_FN)" ] \
  && ok "frame_num=$(get FRAME_NUM) — the true value" \
  || no "frame_num=$(get FRAME_NUM), want $(get TRUE_FN)"
[ "$(get FRAME_NUM)" != "$(get MISREAD_FN_WOULD_BE)" ] \
  && ok "…and NOT $(get MISREAD_FN_WOULD_BE), which a hardcoded 8-bit read yields (the *16 signature)" \
  || no "frame_num shows the hardcoded-width misread signature ($(get MISREAD_FN_WOULD_BE))"
[ "$(get POC_LSB)" = "$(get TRUE_POC)" ] && ok "poc_lsb=$(get POC_LSB) — read at the right bit offset" \
  || no "poc_lsb=$(get POC_LSB), want $(get TRUE_POC)"

echo
echo "== 3. the flags after frame_num are not thrown off =="
# This is what produced the 17 phantom field pictures: every field AFTER a
# mis-sized frame_num is read from the wrong bit offset.
[ "$(get FIELD_PIC)" = 1 ] && ok "field_pic_flag=1 read correctly" || no "field_pic_flag=$(get FIELD_PIC), want 1"
[ "$(get BOTTOM)" = 1 ]    && ok "bottom_field_flag=1 read correctly" || no "bottom_field_flag=$(get BOTTOM), want 1"

echo
echo "== 4. controls: the common SPS and a progressive one still parse =="
[ "$(get CTRL_FRAME_NUM)" = 200 ] && ok "8-bit frame_num still reads 200" || no "CTRL_FRAME_NUM=$(get CTRL_FRAME_NUM)"
[ "$(get CTRL_POC_LSB)" = 250 ]   && ok "8-bit poc_lsb still reads 250" || no "CTRL_POC_LSB=$(get CTRL_POC_LSB)"
[ "$(get CTRL_MAX_POC_LSB)" = 256 ] && ok "…with MaxPicOrderCntLsb 256" || no "CTRL_MAX_POC_LSB=$(get CTRL_MAX_POC_LSB)"
# frame_mbs_only_flag=1 means the slice header carries NO field_pic_flag at all
[ "$(get PROG_FIELD_PIC)" = 0 ] && ok "a progressive SPS yields field_pic=0 (no flag is present to read)" \
  || no "PROG_FIELD_PIC=$(get PROG_FIELD_PIC), want 0"
[ "$(get PROG_FRAME_NUM)" = 7 ] && ok "…and its frame_num is still exact" || no "PROG_FRAME_NUM=$(get PROG_FRAME_NUM), want 7"
[ "$(get PROG_POC_LSB)" = 33 ]  && ok "…and its poc_lsb too (the absent flag did not shift the read)" \
  || no "PROG_POC_LSB=$(get PROG_POC_LSB), want 33"

echo
echo "== 5. the SAME access unit in avcC carriage reads identically =="
# The carriage must be invisible to every value above. A reader that is right
# on Annex-B and blind on avcC is not a correct reader with a gap — it is a
# reader whose jurisdiction was never stated, and three rungs sat on top of it.
[ "$(get AVCC_NLS)" = 4 ] && ok "the minted avcC record declares a 4-byte NAL length" || no "AVCC_NLS=$(get AVCC_NLS), want 4"
[ "$(get AVCC_PS_NALS)" = 2 ] && ok "both parameter sets come back out of extradata (SPS + PPS)" || no "AVCC_PS_NALS=$(get AVCC_PS_NALS), want 2"
[ "$(get AVCC_FRAME_NUM)" = "$(get TRUE_FN)" ] && ok "frame_num=$(get AVCC_FRAME_NUM) — the same true value, from the length-prefixed slice" \
  || no "AVCC_FRAME_NUM=$(get AVCC_FRAME_NUM), want $(get TRUE_FN)"
[ "$(get AVCC_POC_LSB)" = "$(get TRUE_POC)" ] && ok "poc_lsb=$(get AVCC_POC_LSB) — read at the right bit offset in avcC too" \
  || no "AVCC_POC_LSB=$(get AVCC_POC_LSB), want $(get TRUE_POC)"
[ "$(get AVCC_MAX_POC_LSB)" = 64 ] && ok "…and the widths still come from the EXTRADATA SPS (MaxPicOrderCntLsb 64)" \
  || no "AVCC_MAX_POC_LSB=$(get AVCC_MAX_POC_LSB), want 64"
[ "$(get AVCC_FIELD_PIC)" = 1 ] && [ "$(get AVCC_BOTTOM)" = 1 ] \
  && ok "field_pic_flag/bottom_field_flag survive the carriage change" \
  || no "AVCC field flags: field=$(get AVCC_FIELD_PIC) bottom=$(get AVCC_BOTTOM), want 1/1"
[ "$(get AVCC_INBAND_FRAME_NUM)" = "$(get TRUE_FN)" ] && [ "$(get AVCC_INBAND_POC_LSB)" = "$(get TRUE_POC)" ] \
  && ok "in-band avcC (parameter sets inside the packet, no extradata) reads the same" \
  || no "in-band avcC: fn=$(get AVCC_INBAND_FRAME_NUM) poc=$(get AVCC_INBAND_POC_LSB)"

echo
echo "== 6. no constant-width literal survives in the reader =="
# The ported original carried FRAME_NUM_BITS/POC_LSB_BITS/FRAME_MBS_ONLY as
# module constants. Their absence is the structural half of the claim above.
bad=""
for name in FRAME_NUM_BITS POC_LSB_BITS FRAME_MBS_ONLY MAX_POC_LSB; do
  grep -qE "^[[:space:]]*$name[[:space:]]*=" "$SC/h264poc.py" && bad="$bad $name"
done
[ -z "$bad" ] && ok "h264poc.py defines no hardcoded slice-field width" \
  || no "hardcoded width constant(s) back in h264poc.py:$bad"

echo
echo "sps-aware-slice-reader: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
