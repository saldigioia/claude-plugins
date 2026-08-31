#!/usr/bin/env bash
# 118-poc-carriage-and-scale.sh — Rung 3-POC must be able to READ the containers
# it is pointed at, and must count POC in the units its own lattice uses.
#
# WHY, and it is a field measurement (2026-08-30, Reading Festival capture,
# 3.15 GB H.264 1080p50 in Matroska). That file's defect is the one this rung
# exists to repair: 24062 of 138626 pictures (17.4 %) stamped one frame LATE,
# colliding with their neighbour and leaving the slot behind them empty, while
# the bitstream states the truth outright (pts = base + poc * 10). The ladder
# routed it away from the rung, the rung would have refused it, and mov.sh
# shipped a FAIL with the SOURCE named as the review item. Three separate
# defects had to line up for that:
#
#   CARRIAGE  h264poc.iter_nals scanned only for Annex-B start codes. MKV and
#             MOV carry avcC — length-prefixed NALs, parameter sets in
#             extradata — so the reader yielded ZERO NALs and capability() said
#             "no SPS parsed". Same bitstream, two containers, measured:
#                 reord.mkv  pictures=120  parsed=  0   sps_seen=[]
#                 reord.ts   pictures=120  parsed=120   sps_seen=[0]
#             Total blindness vs total success, decided by carriage alone.
#
#   SCALE     H.264 counts POC in FIELDS. A progressive stream codes one
#             picture per FRAME, so POC advances 2 per rung while the container
#             lattice advances 1 — and `k = POC + C` is then a different key for
#             every picture. Field-measured class unanimity: 0.01042. After
#             normalising POC to one unit per rung: 0.80-0.87.
#
#   REACH     pf_poc_routable required PP_PAIRS > 0, so a progressive stream
#             could never route to the rung at all.
#
# NO OUTPUT GATE IS WEAKENED BY ANY OF THIS, and section 5 is that proof: the
# bijection onto the display lattice still refuses, and MIN_SAMPLES is untouched.
#
# Standalone: bash tests/regression.d/118-poc-carriage-and-scale.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rtm118.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3";; esac; }
done_ () { echo; echo "poc-carriage-and-scale: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }

command -v python3 >/dev/null || { echo "SKIP: python3 absent"; echo "poc-carriage-and-scale: 0 passed, 0 failed"; exit 0; }

# THE INTERPRETER THIS RUNG ACTUALLY USES. poc-remux.sh runs on
# $CLAUDE_PLUGIN_DATA/venv/bin/python and nothing else; a suite that tests only
# the system python3 skips its own end-to-end sections on every bench where the
# venv is the only place PyAV lives — which is the documented arrangement. So
# prefer that interpreter when it exists, and say which one is in scope.
PY=python3
RTMDATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
if [ -x "$RTMDATA/venv/bin/python" ] && "$RTMDATA/venv/bin/python" -c 'import av' 2>/dev/null; then
  PY="$RTMDATA/venv/bin/python"
fi

# ---------------------------------------------------------------- section 1 --
# Pure unit work: no media, no PyAV. One synthetic bitstream, both carriages.
echo "== 1. iter_nals reads BOTH standard carriages, and agrees with itself =="
u1=$("$PY" - "$SC" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import h264poc

# One Annex-B buffer with a known NAL roster, and its avcC twin built from the
# SAME payloads. These payloads are EMULATION-PREVENTED (no 00 00 01, no
# 00 00 00) because a valid Annex-B payload must be — that is what makes the
# two carriages comparable at all, and comparing against an invalid twin would
# test the fixture rather than the reader.
payloads = [
    bytes([0x67]) + b"\x42\x00\x1e\x03\x99\x11",          # SPS-typed (7)
    bytes([0x68]) + b"\xce\x3c\x80\x22",                  # PPS-typed (8)
    bytes([0x65]) + b"\x88\x84\x21\x00\x03\x00\x33",      # IDR slice (5)
    bytes([0x41]) + b"\x9a\x24\x6c\x00\x03\x0a\x44",      # non-IDR slice (1)
    bytes([0x06]) + b"\x05\xff\xff\x55",                  # SEI (6)
]
annexb = b"".join(b"\x00\x00\x00\x01" + p for p in payloads)

def avcc(pl, nls):
    out = bytearray()
    for p in pl:
        out += len(p).to_bytes(nls, "big") + p
    return bytes(out)

want = [(p[0] & 0x1F, (p[0] >> 5) & 3) for p in payloads]
print("WANT=%s" % ",".join("%d:%d" % t for t in want))

def roster(buf, nls=None):
    return ",".join("%d:%d" % (t, r) for t, r, _off in h264poc.iter_nals(buf, nls))

print("ANNEXB=%s" % roster(annexb))
for nls in (1, 2, 4):
    print("AVCC%d=%s" % (nls, roster(avcc(payloads, nls), nls)))   # declared size
    print("AUTO%d=%s" % (nls, roster(avcc(payloads, nls))))        # autodetected

# the payload OFFSETS must line up too: a NAL whose header byte is found but
# whose payload start is off by one parses garbage rather than failing
offs_a = [off for _t, _r, off in h264poc.iter_nals(annexb)]
offs_c = [off for _t, _r, off in h264poc.iter_nals(avcc(payloads, 4), 4)]
print("PAYLOAD_A=%s" % ",".join(annexb[o:o+2].hex() for o in offs_a))
print("PAYLOAD_C=%s" % ",".join(avcc(payloads, 4)[o:o+2].hex() for o in offs_c))

# THE avcC-ONLY CLAIM, and it has no Annex-B twin by construction: a
# length-prefixed payload is under no obligation to avoid 00 00 01, and a
# reader that goes looking for start codes inside one invents NALs that are not
# there. The length fields are the only structure, and they must be believed.
escaped = [
    bytes([0x67]) + b"\x42\x00\x00\x01\x99",              # SPS-typed, holds a start code
    bytes([0x41]) + b"\x00\x00\x00\x01\x65\x9a",          # slice, holds a 4-byte one
    bytes([0x06]) + b"\x00\x00\x01\x00\x00\x01",          # SEI, holds two
]
print("ESCWANT=%s" % ",".join("%d:%d" % (p[0] & 0x1F, (p[0] >> 5) & 3) for p in escaped))
print("ESCAPED=%s" % roster(avcc(escaped, 4), 4))

# NEGATIVE CONTROL: a buffer that is neither must yield nothing rather than a
# confident misread. Random-looking bytes with no start code and no exact tiling.
print("JUNK=%s" % roster(b"\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb"))
PY
) || { no "iter_nals raised on a synthetic bitstream"; printf '%s\n' "$u1" | tail -4 | sed 's/^/   /'; }
g1 () { printf '%s\n' "$u1" | sed -n "s/^$1=//p" | head -1; }
W="$(g1 WANT)"
[ -n "$W" ] && [ "$(g1 ANNEXB)" = "$W" ] && ok "Annex-B roster is read (unchanged behaviour)" \
  || no "ANNEXB='$(g1 ANNEXB)' want '$W'"
for nls in 1 2 4; do
  [ "$(g1 "AVCC$nls")" = "$W" ] && ok "avcC roster with a DECLARED ${nls}-byte length matches the Annex-B twin" \
    || no "AVCC$nls='$(g1 "AVCC$nls")' want '$W'"
  [ "$(g1 "AUTO$nls")" = "$W" ] && ok "…and matches with the length size AUTODETECTED by exact tiling" \
    || no "AUTO$nls='$(g1 "AUTO$nls")' want '$W'"
done
[ -n "$(g1 PAYLOAD_A)" ] && [ "$(g1 PAYLOAD_A)" = "$(g1 PAYLOAD_C)" ] \
  && ok "payload_start lands on the same bytes in both carriages" \
  || no "payload offsets differ: A='$(g1 PAYLOAD_A)' C='$(g1 PAYLOAD_C)'"
[ -n "$(g1 ESCWANT)" ] && [ "$(g1 ESCAPED)" = "$(g1 ESCWANT)" ] \
  && ok "avcC payloads holding raw 00 00 01 bytes yield exactly their real NALs, no phantoms" \
  || no "ESCAPED='$(g1 ESCAPED)' want '$(g1 ESCWANT)' — the reader scanned for start codes inside avcC"
[ -z "$(g1 JUNK)" ] && ok "a buffer in NEITHER carriage yields nothing (no confident misread)" \
  || no "junk buffer produced NALs: '$(g1 JUNK)'"

# ---------------------------------------------------------------- PyAV gate --
if ! "$PY" -c 'import av' 2>/dev/null; then
  echo
  echo "  (SKIP sections 2-6: $PY has no PyAV — the container-carriage and"
  echo "   end-to-end claims need a real demuxer)"
  done_; exit
fi
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  echo
  echo "  (SKIP sections 2-6: ffmpeg/ffprobe absent)"
  done_; exit
fi

# ------------------------------------------------------------------ fixtures --
# ONE bitstream, two containers (section 2), plus a progressive stream that is
# LONG enough to clear MIN_SAMPLES=100 per class (sections 3-6). Nothing here is
# tuned to a capture: every number below is measured from the minted file.
echo
echo "-- minting fixtures (one bitstream, two carriages; one progressive stream) --"
ffmpeg -nostdin -loglevel error -f lavfi -i testsrc2=s=320x240:r=30000/1001 \
  -t 4 -c:v libx264 -g 30 -bf 8 -x264opts b-pyramid=normal:b-adapt=0 \
  -pix_fmt yuv420p -y "$WORK/reord.mkv" 2>/dev/null \
  && ffmpeg -nostdin -loglevel error -i "$WORK/reord.mkv" -c copy -y "$WORK/reord.ts" 2>/dev/null \
  || { echo "  (SKIP sections 2-6: the local ffmpeg cannot mint the H.264 fixture)"; done_; exit; }
# 600 pictures over 3 IDR epochs of 200 — so each (epoch, parity) class carries
# 200 votes and MIN_SAMPLES is genuinely cleared rather than skirted.
ffmpeg -nostdin -loglevel error -f lavfi -i testsrc2=s=192x144:r=25 \
  -t 24 -c:v libx264 -g 200 -keyint_min 200 -bf 3 -x264opts b-adapt=0:scenecut=0 \
  -pix_fmt yuv420p -y "$WORK/prog.mkv" 2>/dev/null \
  || { echo "  (SKIP sections 2-6: could not mint the progressive fixture)"; done_; exit; }

# ---------------------------------------------------------------- section 2 --
echo
echo "== 2. the SAME bitstream parses in BOTH containers (the field blindness) =="
u2=$("$PY" - "$SC" "$WORK" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import av, h264poc
work = sys.argv[2]
for name in ("reord.mkv", "reord.ts", "prog.mkv"):
    c = av.open("%s/%s" % (work, name))
    v = c.streams.video[0]
    ex = bytes(getattr(v.codec_context, "extradata", b"") or b"")
    nls = h264poc.avcc_length_size(ex)
    par = h264poc.Parser(nls)
    ps = h264poc.avcc_param_sets(ex)
    if ps:
        par.feed_parameter_sets(ps)
    n = p = 0
    for pkt in c.demux(v):
        if pkt.size == 0:
            continue
        n += 1
        p += par.parse_slice(bytes(pkt)) is not None
    c.close()
    okc, why = par.capability()
    tag = name.replace(".", "_").upper() + "_"
    print("%sN=%d" % (tag, n))
    print("%sPARSED=%d" % (tag, p))
    print("%sSPS=%d" % (tag, len(par.sps)))
    print("%sCAP=%s" % (tag, "ok" if okc else why))
    print("%sNLS=%d" % (tag, nls))
    print("%sPS=%d" % (tag, len(ps)))
PY
) || { no "the reader raised while walking the minted containers"; printf '%s\n' "$u2" | tail -5 | sed 's/^/   /'; }
g2 () { printf '%s\n' "$u2" | sed -n "s/^$1=//p" | head -1; }
for tag in REORD_TS REORD_MKV PROG_MKV; do
  N="$(g2 "${tag}_N")"; P="$(g2 "${tag}_PARSED")"
  { [ -n "$N" ] && [ "$N" -gt 0 ] && [ "$P" = "$N" ]; } \
    && ok "$tag: $P of $N slice header(s) parsed" \
    || no "$tag: $P of $N parsed — the reader is blind to this carriage"
  [ "$(g2 "${tag}_CAP")" = ok ] && ok "$tag: capability() is ok" || no "$tag: capability() = $(g2 "${tag}_CAP")"
done
[ "$(g2 REORD_MKV_NLS)" = 4 ] && ok "the MKV's avcC declares a 4-byte NAL length, and it is READ not guessed" \
  || no "REORD_MKV_NLS=$(g2 REORD_MKV_NLS), want 4"
{ [ "$(g2 REORD_MKV_PS)" -gt 0 ] 2>/dev/null; } && ok "SPS/PPS come out of the MKV's extradata ($(g2 REORD_MKV_PS) bytes)" \
  || no "avcc_param_sets found nothing in the MKV extradata"
[ "$(g2 REORD_TS_NLS)" = 0 ] && ok "an Annex-B (.ts) stream declares NO length size — autodetect is not forced on it" \
  || no "REORD_TS_NLS=$(g2 REORD_TS_NLS), want 0 (not avcC)"
[ "$(g2 REORD_TS_PS)" = 0 ] && ok "…and avcc_param_sets returns nothing for it (no-op on Annex-B)" \
  || no "REORD_TS_PS=$(g2 REORD_TS_PS), want 0"

# ---------------------------------------------------------------- section 3 --
echo
echo "== 3. POC advance is MEASURED, and the classes become unanimous =="
u3=$("$PY" - "$SC" "$WORK" <<'PY'
import sys, collections
sys.path.insert(0, sys.argv[1])
import av, h264poc

c = av.open("%s/prog.mkv" % sys.argv[2])
v = c.streams.video[0]
ex = bytes(getattr(v.codec_context, "extradata", b"") or b"")
par = h264poc.Parser(h264poc.avcc_length_size(ex))
ps = h264poc.avcc_param_sets(ex)
if ps:
    par.feed_parameter_sets(ps)
unw = h264poc.PocUnwrapper()
pts, poc, epoch, bottom = [], [], [], []
prog = 1
for pkt in c.demux(v):
    if pkt.size == 0:
        continue
    sh = par.parse_slice(bytes(pkt))
    pts.append(pkt.pts)
    if sh is None:
        poc.append(None); epoch.append(None); bottom.append(None)
    else:
        p, e = unw.feed(sh)
        poc.append(p); epoch.append(e); bottom.append(sh["bottom"])
c.close()
prog = min(s["frame_mbs_only_flag"] for s in par.sps.values())
print("FRAME_MBS_ONLY=%d" % prog)
print("POC_TYPE=%d" % sorted({s["poc_type"] for s in par.sps.values()})[0])

known = sorted(set(x for x in pts if x is not None))
step = collections.Counter(known[i] - known[i - 1] for i in range(1, len(known))).most_common(1)[0][0]
stamped = [x for x in pts if x is not None]
off = collections.Counter(x % step for x in stamped).most_common(1)[0][0]
k = [None if x is None else (x - off) // step for x in pts]

A, note = h264poc.poc_advance(poc, epoch)
print("ADVANCE=%d" % A)
print("NOTE=%s" % note)

def unanimity(div):
    s = h264poc.RungSolver(100, 0.999)
    for i in range(len(pts)):
        s.vote(epoch[i], bottom[i], k[i], None if poc[i] is None else poc[i] // div)
    s.solve()
    tot = sum(sum(x.values()) for x in s.votes.values())
    best = sum(max(x.values()) for x in s.votes.values())
    return best / float(tot), len(s.votes), min(sum(x.values()) for x in s.votes.values())

raw, ncls, minv = unanimity(1)
norm, _n, _m = unanimity(A)
print("UNAN_RAW=%.5f" % raw)
print("UNAN_NORM=%.5f" % norm)
print("CLASSES=%d" % ncls)
print("MIN_VOTES=%d" % minv)

# THE GUARD, and it is the point of measuring rather than assuming: an ODD POC
# value anywhere must veto normalisation outright. A display position rounded
# away is invented, not read.
odd = list(poc)
for i, p in enumerate(odd):
    if p is not None:
        odd[i] = p + 1
        break
Ao, noteo = h264poc.poc_advance(odd, epoch)
print("ODD_ADVANCE=%d" % Ao)
print("ODD_NOTE=%s" % noteo)
PY
) || { no "the advance measurement raised"; printf '%s\n' "$u3" | tail -5 | sed 's/^/   /'; }
g3 () { printf '%s\n' "$u3" | sed -n "s/^$1=//p" | head -1; }
[ "$(g3 FRAME_MBS_ONLY)" = 1 ] && ok "the fixture is progressive (frame_mbs_only=1) …" || no "fixture is not progressive"
[ "$(g3 POC_TYPE)" = 0 ]       && ok "… and poc_type=0 — the field class this round adds" || no "fixture poc_type=$(g3 POC_TYPE)"
[ "$(g3 ADVANCE)" = 2 ] && ok "measured POC advance = 2 per rung (never assumed: $(g3 NOTE))" \
  || no "ADVANCE=$(g3 ADVANCE), want 2"
awk -v r="$(g3 UNAN_RAW)" 'BEGIN{exit !(r < 0.5)}' \
  && ok "un-normalised class unanimity is $(g3 UNAN_RAW) — structurally unusable" \
  || no "UNAN_RAW=$(g3 UNAN_RAW) — expected the scale defect to show here"
awk -v r="$(g3 UNAN_NORM)" 'BEGIN{exit !(r > 0.75)}' \
  && ok "normalised class unanimity is $(g3 UNAN_NORM) (> 0.75)" \
  || no "UNAN_NORM=$(g3 UNAN_NORM), want > 0.75"
{ [ "$(g3 MIN_VOTES)" -ge 100 ] 2>/dev/null; } && ok "every class carries >= 100 votes ($(g3 MIN_VOTES)) — MIN_SAMPLES is cleared honestly" \
  || no "MIN_VOTES=$(g3 MIN_VOTES) — the fixture skirts MIN_SAMPLES"
[ "$(g3 ODD_ADVANCE)" = 1 ] && ok "one odd POC vetoes normalisation entirely (A=1: $(g3 ODD_NOTE))" \
  || no "ODD_ADVANCE=$(g3 ODD_ADVANCE) — an odd POC was silently rounded away"

# ------------------------------------------------------- mis-stamped fixture --
# The FIELD DEFECT, minted: a fraction of pictures stamped one frame LATE, so
# each lands on its neighbour's slot and leaves its own empty. Video packets are
# copied byte for byte — only container timestamps move, which is exactly what
# the field capture did to itself.
mint () {  # mint SRC DST EVERY [SHIFT_SLOTS]
  "$PY" - "$SC" "$1" "$2" "$3" "${4:-1}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import av
src, dst, every, shift = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
inp = av.open(src)
vin = inp.streams.video[0]
pkts = [(bytes(p), p.pts, p.dts, p.is_keyframe) for p in inp.demux(vin) if p.size]
inp.close()
known = sorted(set(p[1] for p in pkts if p[1] is not None))
step = min(known[i] - known[i - 1] for i in range(1, len(known)))
out = av.open(dst, "w", format="matroska")
inp = av.open(src)
vin = inp.streams.video[0]
try:
    vout = out.add_stream_from_template(vin)
except AttributeError:
    vout = out.add_stream(template=vin)
order = sorted(range(len(pkts)), key=lambda i: pkts[i][1])
moved = set(order[j] for j in range(len(order)) if j % every == 0 and j + shift < len(order))
n = 0
for i, (data, pts, dts, key) in enumerate(pkts):
    np = av.Packet(data)
    np.pts = pts + (step * shift if i in moved else 0)
    np.dts = dts
    np.time_base = vin.time_base
    np.stream = vout
    if key:
        np.is_keyframe = True
    out.mux(np)
    n += 1
out.close()
inp.close()
print("MINTED=%d moved=%d step=%d" % (n, len(moved), step))
PY
}

# ---------------------------------------------------------------- section 4 --
echo
echo "== 4. poc-remux.sh repairs a mis-stamped PROGRESSIVE MKV end to end =="
m4=$(mint "$WORK/prog.mkv" "$WORK/late.mkv" 6 1 2>&1) || { no "could not mint the mis-stamped fixture"; printf '%s\n' "$m4" | tail -3 | sed 's/^/   /'; }
has "$m4" "MINTED=" "the mis-stamped fixture is minted from the clean one"
if [ -f "$WORK/late.mkv" ]; then
  # the defect is REAL before the rung sees it: duplicate display slots present
  dup0=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$WORK/late.mkv" 2>/dev/null | \
         sort | uniq -d | grep -c . || true)
  { [ "${dup0:-0}" -gt 0 ]; } && ok "the minted source really does hold $dup0 doubled display slot(s)" \
    || no "the minted source has no duplicate PTS — the fixture does not carry the defect"
  # essence identity: the mint moved timestamps only
  vh () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null; }
  [ -n "$(vh "$WORK/prog.mkv")" ] && [ "$(vh "$WORK/prog.mkv")" = "$(vh "$WORK/late.mkv")" ] \
    && ok "…and its video essence is bit-identical to the clean fixture (timestamps only)" \
    || no "the mint altered video essence — the fixture is not the field defect"

  mkdir -p "$WORK/realdata/venv/bin"
  cat > "$WORK/realdata/venv/bin/python" <<SH
#!/bin/sh
exec "$PY" "\$@"
SH
  chmod +x "$WORK/realdata/venv/bin/python"
  o4=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" bash "$SC/poc-remux.sh" "$WORK/late.mkv" "$WORK/late.mov" 2>&1); rc4=$?
  { [ "$rc4" -eq 0 ] && [ -f "$WORK/late.mov" ]; } \
    && ok "poc-remux.sh exits 0 and blesses the output" \
    || { no "poc-remux.sh rc=$rc4 (output present: $([ -f "$WORK/late.mov" ] && echo yes || echo no))"; printf '%s\n' "$o4" | tail -20 | sed 's/^/   /'; }
  has "$o4" "POC advance" "the measured POC advance is ANNOUNCED, not silent"
  has "$o4" "dups_moved=" "the POC_SUMMARY machine line reports the adjudication"
  # E4's CONTRACT IS THE ANNOUNCEMENT. The bar is retained as a default and as a
  # measurement, never as a silent pass — a rung that quietly proceeds on
  # unproven evidence is worse than one that refuses, because nobody can tell.
  has "$o4" "evidence bar in force" "the bar in force is printed beside the class report"
  has "$o4" "PROVISIONAL" "…and each class that did not clear it is labelled, not hidden"
  has "$o4" "capped at 1 - f" "the warning names WHY the bar is unreachable here"
  sf=$(printf '%s\n' "$o4" | sed -n 's/.*the weakest is epoch=[0-9]* parity=[a-z]* at \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | awk 'NR<=1')
  # 1 - f is the ceiling and f = 1/6 here, so the shortfall must sit just under
  # 0.834 — not merely "below the bar", which any number is
  awk -v v="${sf:-0}" 'BEGIN{exit !(v > 0.75 && v < 0.90)}' \
    && ok "the warning names its own shortfall ($sf), and it lands at the 1 - f ceiling for f = 1/6" \
    || no "shortfall '$sf' is not the measured 1 - f ceiling (want 0.75 < x < 0.90)"
  if [ -f "$WORK/late.mov" ]; then
    tl=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$WORK/late.mov" 2>/dev/null | \
         sort -n | awk 'NF{ if(n){ d[$1-prev]++ } prev=$1; n++; seen[$1]++ } END{ nd=0; for(k in d) nd++; du=0; for(k in seen) if(seen[k]>1) du++; printf "n=%d distinct_deltas=%d dups=%d\n", n, nd, du }')
    case "$tl" in
      *"dups=0"*) ok "the output holds ZERO duplicate display slots ($tl)";;
      *) no "duplicate slots survive into the output: $tl";;
    esac
    case "$tl" in
      *"distinct_deltas=1"*) ok "…and one single sorted-delta value — the whole grid, no holes";;
      *) no "the output's sorted PTS deltas are not a single value: $tl";;
    esac
    [ -n "$(vh "$WORK/late.mkv")" ] && [ "$(vh "$WORK/late.mkv")" = "$(vh "$WORK/late.mov")" ] \
      && ok "video essence bit-identical source vs deliverable (independent re-hash)" \
      || no "video essence changed through the rung"
  fi
fi

# ---------------------------------------------------------------- section 5 --
echo
echo "== 5. NO OUTPUT GATE IS WEAKENED (the whole round rests on this) =="
# 5a. MIN_SAMPLES is untouched: a class with too few votes yields nothing, and a
# stream whose classes are all short is refused however unanimous they look.
ffmpeg -nostdin -loglevel error -f lavfi -i testsrc2=s=192x144:r=25 \
  -t 4 -c:v libx264 -g 30 -keyint_min 30 -bf 3 -x264opts b-adapt=0:scenecut=0 \
  -pix_fmt yuv420p -y "$WORK/short.mkv" 2>/dev/null || true
if [ -f "$WORK/short.mkv" ]; then
  m5=$(mint "$WORK/short.mkv" "$WORK/shortlate.mkv" 6 1 2>&1) || true
  if [ -f "$WORK/shortlate.mkv" ]; then
    o5=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" bash "$SC/poc-remux.sh" "$WORK/shortlate.mkv" "$WORK/short.mov" 2>&1); rc5=$?
    { [ "$rc5" -eq 3 ] && [ ! -f "$WORK/short.mov" ]; } \
      && ok "short classes (< MIN_SAMPLES votes) -> REFUSED (exit 3), nothing written" \
      || { no "short-class rc=$rc5 (output present: $([ -f "$WORK/short.mov" ] && echo yes || echo no)) — MIN_SAMPLES was weakened"; printf '%s\n' "$o5" | tail -12 | sed 's/^/   /'; }
    has "$o5" "100" "the refusal names the sample bar it enforced"
  fi
fi
# 5b. the knob is real, and it is announced. A knob nothing exercises is a knob
# that breaks silently; and one that changed the bar WITHOUT saying so would put
# back the invisibility this round exists to remove.
if [ -f "$WORK/late.mkv" ]; then
  ok5=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" RTM_POC_MIN_AGREE=0.5 \
        bash "$SC/poc-remux.sh" "$WORK/late.mkv" "$WORK/knob.mov" --dry-run 2>&1) || true
  has "$ok5" "RTM_POC_MIN_AGREE" "a set bar names its SOURCE in the announcement"
  has "$ok5" ">=0.5 unanimity" "…and its value"
  has "$ok5" "TRUSTED" "…and a 0.5 bar the classes DO clear marks them trusted, not provisional"
  bad5=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" RTM_POC_MIN_AGREE=banana \
         bash "$SC/poc-remux.sh" "$WORK/late.mkv" "$WORK/knob.mov" --dry-run 2>&1) || true
  has "$bad5" "is not a number" "an unparseable knob SAYS so rather than deciding a timeline repair"
  has "$bad5" ">=0.999 unanimity" "…and falls back to the documented default"
  hi5=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" RTM_POC_MIN_AGREE=7 \
        bash "$SC/poc-remux.sh" "$WORK/late.mkv" "$WORK/knob.mov" --dry-run 2>&1) || true
  has "$hi5" "outside (0,1]" "a bar outside (0,1] is refused by name, not silently clamped"
  [ -f "$WORK/knob.mov" ] && no "a --dry-run wrote an output" || ok "every knob probe above was a dry run — nothing written"
fi
# 5c. MIN_SAMPLES is a CONSTANT, not an env knob: the round makes the unanimity
# bar overridable and deliberately does NOT make the sample floor overridable.
grep -qE 'RTM_POC_MIN_SAMPLES' "$SC/poc-remux.py" "$SC/derive-dts.py" "$SC/h264poc.py" \
  && no "MIN_SAMPLES gained an env override — the round widens the bar, not the floor" \
  || ok "MIN_SAMPLES has no env override in any of the three POC readers"
# 5d. the bijection onto the display lattice is still the authority, and it is
# still FATAL — the refusal text and the exit are both pinned.
grep -q 'len(set(rk)) != m' "$SC/poc-remux.py" \
  && ok "poc-remux.py still refuses unless every frame lands on its OWN slot" \
  || no "the bijection check is gone from poc-remux.py"
grep -q 'is not shipped' "$SC/poc-remux.py" \
  && ok "…and still says so in the refusal (two pictures on one slot is not shipped)" \
  || no "the bijection refusal prose is gone"
# the DTS asserts that follow it are the second half of the same guarantee
grep -q 'assert all(fdts\[i\] > fdts\[i - 1\]' "$SC/poc-remux.py" \
  && ok "DTS monotonicity is still asserted after adjudication" || no "the DTS monotonic assert is gone"
grep -q 'assert all(fdts\[i\] <= fpts\[i\]' "$SC/poc-remux.py" \
  && ok "DTS <= PTS is still asserted" || no "the DTS <= PTS assert is gone"
# 5e. the driver still runs the FULL verify suite before blessing anything
grep -q 'verify.sh' "$SC/poc-remux.sh" && ok "poc-remux.sh still gates its own output through verify.sh" \
  || no "the verify.sh output gate is gone from poc-remux.sh"

# ---------------------------------------------------------------- section 6 --
echo
echo "== 6. pf_poc_routable reaches the progressive-contradicted class =="
r6=$(cd "$SC" && bash -c '
  set -uo pipefail
  . ./lib-probe.sh; . ./lib-paff.sh
  # the progressive-CONTRADICTED profile: H.264, POC-capable, reordered, no
  # field pairs at all, and the container timestamps contradict the lattice
  PF_CODEC=h264 PCAP_OK=yes PP_PAIRS=0 PF_HALF_TS=no PF_REORDER=yes \
    DGC_DUPPKTS=24062 DGC_N=138626 \
    pf_poc_routable && echo "PROG_CONTRA=yes" || echo "PROG_CONTRA=no"
  # a CLEAN progressive stream: same profile, nothing contradicted -> not ours
  PF_CODEC=h264 PCAP_OK=yes PP_PAIRS=0 PF_HALF_TS=no PF_REORDER=yes \
    DGC_DUPPKTS=0 DGC_N=138626 DGC_NA=0 \
    pf_poc_routable && echo "PROG_CLEAN=yes" || echo "PROG_CLEAN=no"
  # the field class that already routed must KEEP routing (no regression)
  PF_CODEC=h264 PCAP_OK=yes PP_PAIRS=208014 PF_HALF_TS=no PF_REORDER=yes \
    DGC_DUPPKTS=0 DGC_N=424596 DGC_NA=0 \
    pf_poc_routable && echo "PAFF=yes" || echo "PAFF=no"
  # and the negatives still refuse: not H.264, not POC-capable, the half-ts
  # signature (pairfill owns it), and a non-reordered stream
  PF_CODEC=mpeg2video PCAP_OK=yes PP_PAIRS=0 PF_HALF_TS=no PF_REORDER=yes DGC_DUPPKTS=99 DGC_N=100 \
    pf_poc_routable && echo "NOTH264=yes" || echo "NOTH264=no"
  PF_CODEC=h264 PCAP_OK=no PP_PAIRS=0 PF_HALF_TS=no PF_REORDER=yes DGC_DUPPKTS=99 DGC_N=100 \
    pf_poc_routable && echo "NOCAP=yes" || echo "NOCAP=no"
  PF_CODEC=h264 PCAP_OK=yes PP_PAIRS=0 PF_HALF_TS=yes PF_REORDER=yes DGC_DUPPKTS=99 DGC_N=100 \
    pf_poc_routable && echo "HALFTS=yes" || echo "HALFTS=no"
  PF_CODEC=h264 PCAP_OK=yes PP_PAIRS=0 PF_HALF_TS=no PF_REORDER=no DGC_DUPPKTS=99 DGC_N=100 \
    pf_poc_routable && echo "NOREORDER=yes" || echo "NOREORDER=no"
' 2>&1)
g6 () { printf '%s\n' "$r6" | sed -n "s/^$1=//p" | head -1; }
[ "$(g6 PROG_CONTRA)" = yes ] && ok "progressive + contradicted display slots ROUTES to Rung 3-POC" \
  || { no "the progressive-contradicted profile is still unroutable"; printf '%s\n' "$r6" | tail -4 | sed 's/^/   /'; }
[ "$(g6 PROG_CLEAN)" = no ]   && ok "a CLEAN progressive stream does not route (no defect to repair)" || no "a clean progressive stream routes to the repair rung"
[ "$(g6 PAFF)" = yes ]        && ok "the field-coded class that already routed still routes" || no "REGRESSION: the PAFF class no longer routes"
[ "$(g6 NOTH264)" = no ]      && ok "non-H.264 still refuses" || no "a non-H.264 stream routes to an H.264-only rung"
[ "$(g6 NOCAP)" = no ]        && ok "a stream that cannot state its POC still refuses" || no "a POC-incapable stream routes"
[ "$(g6 HALFTS)" = no ]       && ok "the half-timestamped pair signature still belongs to pairfill" || no "half_ts routed here"
[ "$(g6 NOREORDER)" = no ]    && ok "a non-reordered stream still refuses" || no "a non-reordered stream routes"


# ---------------------------------------------------------------- section 7 --
echo
echo "== 7. THE LADDER REACHES THE RUNG, unattended (the field regression) =="
# Sections 4-6 prove the rung works and the predicate describes the class. This
# proves the two are CONNECTED, which is the whole complaint the round started
# from: on 2026-08-30 mov.sh took the direct copy path on a progressive source,
# hard-stopped on the muxer's own timeline confessions, and exited 1 — with the
# rung built to repair exactly that defect one branch away and never reached.
# Three separate gates had to open for it: mov.sh handed off to auto.sh only on
# PF_PAFF (a fact about CODING, not about the timeline), probe.sh's derive
# recommendation took a branch that never offered 3-POC, and pf_poc_routable
# could not describe a progressive stream at all.
if [ -f "$WORK/late.mkv" ] && [ -x "$WORK/realdata/venv/bin/python" ]; then
  o7=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" timeout 900 bash "$SC/mov.sh" \
         "$WORK/late.mkv" "$WORK/ladder.mov" 2>&1); rc7=$?
  { [ "$rc7" -eq 0 ] && [ -f "$WORK/ladder.mov" ]; } \
    && ok "mov.sh alone repairs the mis-stamped progressive source (exit 0)" \
    || { no "mov.sh rc=$rc7 (output present: $([ -f "$WORK/ladder.mov" ] && echo yes || echo no))"; printf '%s\n' "$o7" | tail -18 | sed 's/^/   /'; }
  has "$o7" "CONTRADICT" "the front door NAMES the contradiction it routed on"
  has "$o7" "best_rung=3-poc" "the ladder settles on Rung 3-POC, not a fallback"
  hs7=$(printf '%s\n' "$o7" | grep -c 'HARD STOP' || true)
  [ "${hs7:-0}" -eq 0 ] && ok "no muxer timeline confession anywhere in the run" \
    || no "$hs7 hard stop(s) — the copy rung still got a timeline it had to invent around"
  lat=$(printf '%s\n' "$o7" | grep -oE 'VERIFY_POC_LATTICE on_slot=[0-9]+ total=[0-9]+ off=[0-9]+' | awk 'NR<=1')
  case "$lat" in
    *" off=0") ok "every picture lands on its own POC slot ($lat)";;
    "") no "no VERIFY_POC_LATTICE line — gate (k) did not judge this artifact";;
    *) no "off-slot pictures survive: $lat";;
  esac
  # the deliverable is lossless against the UNTOUCHED clean source, not merely
  # against the mis-stamped one: only timestamps were ever meant to move
  vh2 () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null; }
  { [ -f "$WORK/ladder.mov" ] && [ -n "$(vh2 "$WORK/prog.mkv")" ] \
      && [ "$(vh2 "$WORK/prog.mkv")" = "$(vh2 "$WORK/ladder.mov")" ]; } \
    && ok "video essence bit-identical to the CLEAN source (the mis-stamp was timestamps only)" \
    || no "essence differs from the clean source"
else
  echo "  (SKIP: the mis-stamped fixture or the venv shim from section 4 is unavailable)"
fi

done_
