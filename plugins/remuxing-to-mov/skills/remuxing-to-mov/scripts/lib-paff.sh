#!/usr/bin/env bash
# lib-paff.sh — shared field-coded (PAFF) H.264 detection. SOURCE this, don't run it.
# Used by probe.sh, diagnose.sh, verify.sh so the three never disagree on what PAFF is.
#
# The programmatic PAFF tell (no decode required): in field-coded H.264 each FIELD
# picture is its own coded picture / access unit, so the coded-picture rate runs
# ~2x the container's frame rate (e.g. ~60 AU/s on 29.97p content — the exact
# signature behind the corrupted-file post-mortem). Progressive and frame-coded
# interlaced (MBAFF) both sit at ~1x and are NOT the fragile case. field_order
# tt/bb corroborates and is reported, but the rate ratio is the decisive test
# (some captures/builds report field_order=unknown even when field-coded).
#
# COUNT EVERY PACKET, not just timestamped ones (post-mortem 2026-07-25): real
# broadcast PAFF often carries PES timestamps only on the FIRST field of each
# pair — the second field of every pair has no PTS and no DTS at all. A rate
# computed from timestamped packets alone reads ~1x on exactly those captures
# and reports paff=no: the false negative that routed a broken timeline to the
# wrong repair rung. So the numerator counts ALL packets in the window; only the
# time SPAN comes from the timestamped ones. The untimestamped fraction itself
# is exported (PF_NOPTS_FRAC / PF_HALF_TS) — ~50% missing IS the pair signature.
#
# Usage:
#   . "$(dirname "$0")/lib-paff.sh"
#   eval "$(pf_detect INPUT)"
#   # -> PF_CODEC PF_FIELD PF_CODED_RATE PF_CODED_RATE_SPAN PF_RATE_METHOD
#   #    PF_NOMINAL_FPS PF_RATIO PF_RATIO_HYP PF_PAFF PF_PPF
#   #    PF_FIELD_RATE PF_TIMESCALE PF_NOPTS PF_NOPTS_FRAC PF_HALF_TS
#   #    (PF_PAFF / PF_HALF_TS are yes|no)
#
# Every function is a read-only probe; none touch the source.

# every probe here opens broadcast inputs -> the raised probe window applies
# (ffp wrapper + FF_INPUT_OPTS; see lib-probe.sh for the misprobe post-mortem)
PF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$PF_LIB_DIR/lib-probe.sh"

# --- one named window for the advisory-tier timestamp scans (P1.1) ------------
# pf_reorder_scan used 3000 packets and diagnose.sh's dup/backward-DTS scan used
# 5000, for no recorded reason — two numbers for one idea, and the prose quoted
# whichever the writer remembered. Reconciled here: "the windowed scan" is ONE
# number everywhere it is measured or quoted (probe.sh prints it from this
# variable rather than hardcoding it again).
# THE RECONCILED VALUE IS THE LARGER ONE, 5000 (F8, 2026-08-16). The first
# reconciliation picked 3000 and thereby SHRANK the window feeding a gate:
# diagnose.sh step (3) produces ndup/nback, which arm the rot verdict at
# diagnose.sh's verdict block, so 3000 was strictly less evidence than the
# 5000 that arm had always seen. Never reduce what a gate is shown. The scans
# are demux-only and the extra 2000 packets are cheap: measured on this bench
# 2026-08-16 (ffprobe 9.0.1, macOS 26.6.1) against a 78.9 MB / 10,000-packet
# 200 s H.264 TS, a `-show_entries packet=dts` read of the head takes 0.134 s
# at 3000 and 0.304 s at 5000 (best of 9 each) — +0.17 s, once, per advisory
# report. No pinned assertion depended on either value.
# NOT the same knob as trim-to-idr.sh's RTM_IDR_WINDOW (how far to hunt for the
# first IDR); that one is unrelated and deliberately untouched.
PF_SCAN_WINDOW="${PF_SCAN_WINDOW:-5000}"
# essence (decode) probe window for coded-pictures-per-frame. Deliberately the
# SAME 240 as the coded-rate window: a decode costs far more per packet than a
# demux, so the essence probe stays as small as the question allows.
PF_PPF_WINDOW="${PF_PPF_WINDOW:-240}"
# ffprobe stderr lines tolerated behind a declared SPS value before the
# declaration is called unreadable rather than believed. THIS NUMBER IS A
# CALIBRATION, NOT A PROOF: nothing derives 20 from the format: it is a cut
# placed in measured daylight between two classes, and it is the only thing
# standing between the undecodable-head class and a false ppf=2 (see
# pf_ppf_probe). Re-measured on this bench 2026-08-16 (ffprobe 9.0.1, macOS
# 26.6.1, PF_PPF_WINDOW=240) — every figure below is one `grep -c .` of the
# probe's own stderr, deterministic across three repeats:
#     has_b_frames read   gap.ts 0   aac.ts 0   m2v420.ts 0   late-sps.ts 306
#     ppf essence probe   gap.ts 0   aac.ts 0   m2v420.ts 0   late-sps.ts 308
# i.e. daylight from 0 to ~300 on both probes, and 20 sits inside it with two
# orders of magnitude of margin on each side. (The flood SIZE is a property of
# this bench's locally minted late-sps.ts — tests/make-fixtures.sh — so treat
# 306/308 as "hundreds", not as a constant; the SEPARATION is the invariant.)
PF_SPS_NOISE_MAX="${PF_SPS_NOISE_MAX:-20}"

# evaluate an ffprobe rate fraction ("60000/1001") to a decimal; "0" if unusable
pf_eval_fps () {
  awk "BEGIN{n=split(\"${1:-0}\",a,\"/\"); if(n<2||a[2]+0==0) printf \"%.4f\",a[1]+0; else printf \"%.4f\",a[1]/a[2]}"
}

# coded-picture rate over a bounded packet window (demux only, NO decode).
# EVERY packet counts toward the rate — untimestamped ones included (they are still
# coded pictures); only the TIME base comes from timestamped packets. Skipping the
# untimestamped ones halves the measured rate on pair-timestamped PAFF captures
# and produces the paff=no false negative (post-mortem 2026-07-25).
#
# P1.5 — the reorder LEAD BIAS. Until now the time base was the min/max timestamp
# SPAN of the window. On a reorder pyramid that span is not (n-1) picture
# durations: the last few coded pictures present AHEAD of the window's end, so
# the span runs long by exactly the reorder depth D and the rate reads
# (n-1)/((n-1+D)*d) instead of 1/d. Measured on this bench 2026-08-16 (ffprobe
# 9.0.1, macOS 26.6.1) against the constructed D=2 / 59.94 pyramid the suite
# pins — tests/regression.d/61-reorder-depth.sh section 5, fed in through the
# PF_PKT_FILE hook, because a real one cannot be minted in a sandbox:
#     pf_coded_rate -> 59.9413 (modal)  vs  59.4385 (legacy min/max span)
# i.e. the span method loses half a frame per second to the reorder lead alone.
# The MODAL delta between presentation-sorted timestamps carries no such lead
# (the pyramid's excursions cancel: sorted, the pictures are one duration
# apart), so the window rate is derived from it instead:
#     rate = (total_pkts - 1) / ((timestamped_pkts - 1) * modal_delta)
# which is IDENTICAL to the old formula on an evenly-spaced window (the pair
# class included: 240 packets / 120 timestamps still reads ~60 AU/s) and
# unbiased on a pyramid. When the modal delta has weak support (<25% of the
# deltas — genuine VFR, or a window too ragged to have a cadence) the legacy
# span figure is used and the method says so, rather than pretending a mode.
# Emits: "RATE TOTAL_PKTS UNTIMESTAMPED_PKTS SPAN_RATE METHOD" — the first three
# are the unchanged positional API; SPAN_RATE (the legacy number) and METHOD
# (modal|span) are appended so the change can ANNOUNCE itself old-vs-new.
# Test hook: PF_PKT_FILE=<csv of pts_time,dts_time lines> bypasses ffprobe.
pf_coded_rate () {
  { if [ -n "${PF_PKT_FILE:-}" ]; then cat "$PF_PKT_FILE"; else
      ffp -v error -select_streams v:0 -read_intervals "%+#240" \
        -show_entries packet=pts_time,dts_time -of csv=p=0 "$1" 2>/dev/null; fi; } | \
  awk -F, 'NF{t=$1; if(t=="N/A"||t==""){t=$2}; n++;
            if(t=="N/A"||t==""){miss++; next}
            v[++m]=t+0
            if(!seen){mn=mx=t+0;seen=1} else {if(t+0<mn)mn=t+0; if(t+0>mx)mx=t+0}}
           END{
             span=mx-mn; sr=0
             if(seen && span>0 && n>1) sr=(n-1)/span
             # insertion sort — m <= 240 here, so the O(m^2) worst case is ~29k
             # comparisons: cheaper than shelling out to sort(1) per call
             for(i=2;i<=m;i++){ x=v[i]; j=i-1; while(j>=1 && v[j]>x){ v[j+1]=v[j]; j-- } v[j+1]=x }
             best=0; bc=0; nd=0
             for(i=2;i<=m;i++){ d=v[i]-v[i-1]; if(d<=0) continue; nd++
                                k=sprintf("%.6f",d); c[k]++; if(c[k]>bc){ bc=c[k]; best=k+0 } }
             rate=sr; meth="span"
             if(best>0 && nd>0 && bc>=0.25*nd && m>1 && n>1){ rate=(n-1)/((m-1)*best); meth="modal" }
             printf "%.4f %d %d %.4f %s", rate, n+0, miss+0, sr, meth
           }'
}

# --- P1.1 unit-aware reorder depth: the three probes the classifier needs -----
# WHY these are separate, small functions: the 2023-VMA class is a UNITS defect,
# and each of the three numbers that decide it comes from a different kind of
# evidence. Mixing them into one scanner is how the units got lost the first
# time. There is exactly ONE reorder scanner (pf_reorder_scan below) and it
# consumes these; never add a second scanner.

# pf_decl_depth INPUT -> "<has_b_frames|unknown> <parse-error-lines>"
# The DECLARED depth, in FRAMES, as ffprobe reports it from the SPS.
# unknown != zero: on the late-sps.ts class ffprobe still prints
# has_b_frames=1 — underneath a 306-line error flood (re-measured on this
# bench 2026-08-16, ffprobe 9.0.1, macOS 26.6.1; the "195" written here before
# is not what this read produces). A number produced by a parser that is
# simultaneously
# screaming is not a declaration, and letting it through is exactly how an
# unreadable SPS would route as `understated` (a non-conformance verdict) on
# evidence that cannot support one. Both the value and the noise count are
# returned so the caller can print the raw evidence.
# Test hook: PF_DECL_DEPTH_IN bypasses ffprobe.
pf_decl_depth () {
  local tmp d n
  if [ -n "${PF_DECL_DEPTH_IN:-}" ]; then printf '%s 0' "$PF_DECL_DEPTH_IN"; return 0; fi
  tmp=$(mktemp -t rtmdecl.XXXXXX 2>/dev/null) || { printf 'unknown 0'; return 0; }
  d=$(ffp -v error -select_streams v:0 -show_entries stream=has_b_frames \
        -of default=nw=1:nk=1 "$1" 2>"$tmp" | head -1)
  n=$(grep -c . "$tmp" 2>/dev/null || true); rm -f "$tmp"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  case "$d" in ''|*[!0-9]*) d=unknown;; esac
  [ "$n" -ge "$PF_SPS_NOISE_MAX" ] && d=unknown
  printf '%s %s' "$d" "$n"
}

# pf_ppf_probe INPUT -> 1|2|unknown  (coded pictures per FRAME)
# This needs an ESSENCE probe, not a timestamp one. Timestamps cannot tell
# 59.94p apart from 59.94 fields — that ambiguity IS the bug — so the question
# is answered by the only party that knows: the decoder. Bounded
# decode-count-vs-packet-count over PF_PPF_WINDOW packets; on PAFF the H.264
# decoder emits one frame per FIELD PAIR, so frames ~= packets/2.
# Inconclusive returns `unknown` and NEVER a guess. Re-measured on this bench
# 2026-08-16 (ffprobe 9.0.1, macOS 26.6.1, PF_PPF_WINDOW=240), frames/packets
# straight out of the probe below:
#     gap.ts 240/240 = 1.000   aac.ts 125/125 = 1.000   m2v420.ts 125/125 = 1.000
#     late-sps.ts    138/240 = 0.575
# (The earlier "500/500 and 125/125 ... late-sps 375/477 = 0.79" written here
# was arithmetically impossible for this probe — the window CAPS the numerator
# at PF_PPF_WINDOW=240, and 500/477 are whole-file packet counts from the
# PF_SCAN_WINDOW scan, a different measurement entirely.)
# NOTE WHAT 0.575 MEANS: it is INSIDE the 0.40–0.60 ppf=2 band. The ratio does
# NOT rescue this file — the stderr-noise guard below does. See there.
# field_order is NOT consulted here: MBAFF and frame-coded interlace set it too,
# so it corroborates and never decides.
# Test hook: PF_PPF_IN bypasses the probe; an injected packet hook makes the run
# hermetic (no ffprobe at all) and therefore `unknown` unless PF_PPF_IN is given.
pf_ppf_probe () {
  local in="${1:-}" tmp np nf ne
  if [ -n "${PF_PPF_IN:-}" ]; then printf '%s' "$PF_PPF_IN"; return 0; fi
  if [ -n "${PF_PKT_TICKS_FILE:-}${PF_PKT_FILE:-}" ]; then printf 'unknown'; return 0; fi
  tmp=$(mktemp -t rtmppf.XXXXXX 2>/dev/null) || { printf 'unknown'; return 0; }
  # shellcheck disable=SC2046  # word splitting is the point: "PACKETS FRAMES"
  set -- $(ffp -v error -select_streams v:0 -read_intervals "%+#${PF_PPF_WINDOW}" \
             -show_entries packet=pts:frame=width -of compact "$in" 2>"$tmp" | \
           awk '/^packet\|/{p++} /^frame\|/{f++} END{printf "%d %d", p+0, f+0}')
  np="${1:-0}"; nf="${2:-0}"
  ne=$(grep -c . "$tmp" 2>/dev/null || true); rm -f "$tmp"
  case "$ne" in ''|*[!0-9]*) ne=0;; esac
  # A DECODER THAT IS ERRORING IS NOT COUNTING. The undecodable-head class
  # (late-sps.ts) reads 138 frames from 240 packets — 0.575, dead inside the
  # ppf=2 band — purely because the pre-SPS packets produce no frame at all.
  # THIS GUARD IS THE ONLY THING STOPPING A FALSE ppf=2 ON THAT FILE, and a
  # false ppf=2 is a false PAFF positive (H2 in pf_detect would accept it).
  # The ratio cannot help: 0.575 is a normal ppf=2 reading. So the same noise
  # discipline as pf_decl_depth applies — re-measured on this bench 2026-08-16
  # (ffprobe 9.0.1, macOS 26.6.1): this probe emits 0 stderr lines on
  # gap.ts / aac.ts / m2v420.ts and 308 on late-sps.ts, deterministic across
  # three repeats. PF_SPS_NOISE_MAX=20 is a CALIBRATION inside that daylight,
  # not a proof (see the constant's own note). Flooding -> unknown, and
  # unknown never routes as yes.
  [ "$ne" -ge "$PF_SPS_NOISE_MAX" ] && { printf 'unknown'; return 0; }
  [ "${np:-0}" -lt 40 ] && { printf 'unknown'; return 0; }
  awk "BEGIN{r=${nf:-0}/${np:-1};
       if(r>=0.40 && r<=0.60) printf \"2\";
       else if(r>=0.85 && r<=1.15) printf \"1\";
       else printf \"unknown\"}"
}

# pf_dts_source INPUT -> carried|reconstructed
# Whether the DTS column the demuxer hands us is a CONTAINER FACT or ffmpeg's
# reconstruction. Matroska stores no DTS, ever — one timestamp per block — so
# every dts on an .mkv is invented by the demuxer's reorder model, and any
# measurement keyed to it measures the model, not the source. Raw elementary
# streams (h264/hevc/mpegvideo/m4v) carry no container timestamps at all, same
# verdict. MPEG-TS PES and MOV stts/ctts DO carry decode timing: carried.
# Test hook: PF_DTS_SOURCE_IN bypasses ffprobe.
pf_dts_source () {
  local c="${PF_DTS_SOURCE_IN:-}"
  case "$c" in carried|reconstructed) printf '%s' "$c"; return 0;; esac
  c=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "${1:-}" 2>/dev/null | head -1)
  case "$c" in
    *matroska*|*webm*)                 printf 'reconstructed';;
    h264|hevc|mpegvideo|m4v|*,h264,*|*,hevc,*|*,mpegvideo,*|*,m4v,*) printf 'reconstructed';;
    '')                                printf 'carried';;
    *)                                 printf 'carried';;
  esac
}

# reorder profile over a bounded head window (demux only, NO decode): does the
# stream carry a presentation-reorder pyramid (B-frames / B-fields)? Measured
# from packets where BOTH pts and dts are present: pts!=dts occurrences, backward
# pts steps, and the max pts-dts offset in stream ticks. Decides which repair is
# legitimate: a constant-rate restamp (rebuild-paff.sh) sets PTS=DTS and plays a
# reordered stream in DECODE order — motion shuffled, a different way of being
# broken (post-mortem 2026-07-25). Reordered streams need their real PTS kept —
# half-timestamped PAFF via pairfill-paff.sh; a PTS-COMPLETE reordered stream
# via derive-dts.sh (Rung 3-DERIVE, WO 1.14: the DTS column is re-derived from
# the sorted PTS, codec-agnostic).
#
# P1.1 UNIT-AWARE REORDER DEPTH (additive fields, same single scan). The 2023
# VMA capture — 54.6 GB of ordinary field-coded broadcast H.264 in Matroska —
# produced 163,859 non-monotonic DTS events out of nothing: Matroska stores no
# DTS, ffmpeg reconstructs it from has_b_frames, and has_b_frames counts FRAMES
# while the packets are FIELDS, so the reconstructed delay is short by exactly
# the field factor. The SPS is correct (max_num_reorder_frames=2 frames = 4
# fields, conforming). Nothing downstream could see that, because nothing
# measured the depth in the unit the packets are actually in. So:
#   PF_DEPTH_PICS  D, the MEASURED reorder depth in CODED PICTURES, from the PTS
#                  column alone (zero DTS needed — which is the point on a
#                  container that has none): D = max(i - rank(pts[i])), i.e. the
#                  largest distance any picture travels between coded position
#                  and presentation position.
#   PF_DECL_DEPTH  has_b_frames, the DECLARED depth in FRAMES (or unknown).
#   PF_PPF         coded pictures per frame, from the essence probe (or unknown).
#   PF_DEPTH_CLASS none | match-frame | match-field | understated | unknown,
#                  where expected = PF_DECL_DEPTH * PF_PPF:
#                    D >  expected             -> understated  (genuinely
#                      non-conforming; rarer, and a different root cause)
#                    D == expected, ppf 1      -> match-frame  (ordinary
#                      progressive; with ppf 1, expected == decl)
#                    ppf 2, decl < D <= expected -> match-field (the VMA class)
#                    otherwise (D <= decl, D==0 included) -> none
#                    either input unknown      -> unknown, which must never be
#                      allowed to route as `understated`.
#                  F3 (2026-08-16) WIDENED match-field from `D == expected` to
#                  the whole band above decl. The class is defined by its
#                  MECHANISM, not by an exact equality: ffmpeg applies
#                  has_b_frames PACKETS of delay, so on a reconstructed-DTS
#                  container ANY D above the declared frame count leaves the
#                  reconstruction short — wholly (D == expected) or partly
#                  (decl < D < expected, a sample that does not exercise the
#                  full declared depth). The old rule sent that intermediate
#                  band to `none` — "no reorder worth mentioning" — on files
#                  that need exactly the same derivation as the VMA capture.
#                  Observed on this tree before the fix: D=3 decl=2 ppf=2
#                  expected=4 -> none, and silently (pf_depth_note had no arm
#                  for it). With ppf 1 the band is EMPTY (expected == decl), so
#                  progressive classification is bit-for-bit unchanged.
#   PF_DTS_SHORT   yes|no|unknown — the ROUTING discriminant, and the reason the
#                  band above matters. True exactly when D > PF_DECL_DEPTH, i.e.
#                  when the measured depth in PACKETS exceeds the packet delay
#                  ffmpeg will apply. That, not the class label, is the fact a
#                  repair must dispatch on: a `yes` on PF_DTS_SOURCE=
#                  reconstructed IS the non-monotonic-DTS generator. It is
#                  independent of ppf (understated streams are short too).
#   PF_DTS_SOURCE  carried|reconstructed — see pf_dts_source.
# The measurement is a SAMPLE (PF_SCAN_WINDOW packets from the head) and a
# sample can only ever UNDERSTATE D: a deeper excursion may sit outside the
# window. PF_DEPTH_TS reports how many timestamped pictures it was measured
# over so the reader can weigh it; every printer of the class says so out loud.
# Test hooks: PF_PKT_TICKS_FILE=<csv of pts,dts integer-tick lines> bypasses
# ffprobe; PF_DECL_DEPTH_IN / PF_PPF_IN / PF_DTS_SOURCE_IN inject the three
# non-timestamp inputs so the classifier can be pinned hermetically.
pf_reorder_scan () {
  local in="${1:-}" raw depth n_ts decl noise ppf dsrc expected cls short
  raw=$( if [ -n "${PF_PKT_TICKS_FILE:-}" ]; then cat "$PF_PKT_TICKS_FILE"; else
           ffp -v error -select_streams v:0 -read_intervals "%+#${PF_SCAN_WINDOW}" \
             -show_entries packet=pts,dts -of csv=p=0 "$in" 2>/dev/null; fi )
  printf '%s\n' "$raw" | \
  awk -F, 'NF{
      p=$1; d=$2; tot++
      if(p!="N/A" && p!=""){ if(havep && p+0<pp) back++; pp=p+0; havep=1 }
      if(p=="N/A"||p==""||d=="N/A"||d=="") next
      both++; off=p-d; if(off!=0) ne++; if(off>mx) mx=off
    }
    END{
      r="no"; if(ne>0 || back>0) r="yes"
      printf "PF_REORDER=%s\nPF_PTSNEDTS=%d\nPF_BACKPTS=%d\nPF_MAXOFF_TICKS=%d\nPF_TS_BOTH=%d\n", r, ne+0, back+0, mx+0, both+0
    }'
  # depth arm: number the timestamped pictures in CODED order, re-read them in
  # PRESENTATION order (the same `sort -n` discipline verify gate (e) uses), and
  # keep the largest coded-index-minus-presentation-rank. Pure ranking — no DTS
  # is touched anywhere in this computation.
  # shellcheck disable=SC2046  # word splitting is the point: "DEPTH N_TIMESTAMPED"
  set -- $(printf '%s\n' "$raw" | \
           awk -F, 'NF && $1!="N/A" && $1!=""{ printf "%s %d\n", $1, ++i }' | \
           LC_ALL=C sort -n | \
           awk '{ k++; d=$2-k; if(d>mx) mx=d } END{ printf "%d %d", mx+0, k+0 }')
  depth="${1:-0}"; n_ts="${2:-0}"
  # shellcheck disable=SC2046  # word splitting is the point: "DEPTH NOISE_LINES"
  set -- $(pf_decl_depth "$in"); decl="${1:-unknown}"; noise="${2:-0}"
  ppf=$(pf_ppf_probe "$in"); dsrc=$(pf_dts_source "$in")
  cls=unknown; expected=unknown; short=unknown
  # PF_DTS_SHORT needs only the DECLARED depth — ffmpeg's delay is has_b_frames
  # PACKETS whatever the pictures-per-frame turns out to be — so it is answered
  # here, BEFORE the ppf-dependent classifier, and survives PF_PPF=unknown.
  case "$decl" in
    ''|*[!0-9]*) : ;;
    *) if [ "$depth" -gt "$decl" ]; then short=yes; else short=no; fi ;;
  esac
  case "$decl:$ppf" in
    unknown:*|*:unknown) : ;;
    *) expected=$(( decl * ppf ))
       # ORDER IS THE RULE (F3): over-expected first, then the exact
       # progressive match, then the whole ppf=2 band ABOVE the declared frame
       # count — which is where the reader's packet delay starts coming up
       # short. Everything at or below decl is `none`: the delay covers it.
       if   [ "$depth" -le 0 ];                                   then cls=none
       elif [ "$depth" -gt "$expected" ];                         then cls=understated
       elif [ "$depth" -eq "$expected" ] && [ "$ppf" -eq 1 ];     then cls=match-frame
       elif [ "$ppf" -eq 2 ] && [ "$depth" -gt "$decl" ];         then cls=match-field
       else cls=none; fi ;;
  esac
  printf 'PF_DEPTH_PICS=%s\nPF_DEPTH_TS=%s\nPF_DECL_DEPTH=%s\nPF_SPS_NOISE=%s\nPF_PPF=%s\nPF_DEPTH_EXPECTED=%s\nPF_DEPTH_CLASS=%s\nPF_DTS_SHORT=%s\nPF_DTS_SOURCE=%s\n' \
    "${depth:-0}" "${n_ts:-0}" "$decl" "${noise:-0}" "$ppf" "$expected" "$cls" "$short" "$dsrc"
}

# pf_depth_note CLASS DEPTH DECL PPF EXPECTED SAMPLED — the one human sentence
# every printer of the depth fields uses, so probe/diagnose can never diverge on
# what a class MEANS. Every class now has an arm: `none` used to fall through
# the case and print nothing, which is how the D=3/decl=2 band reached a reader
# in total silence (F3, 2026-08-16). The DTS-short line below is derived from
# DEPTH vs DECL — the same rule pf_reorder_scan emits as PF_DTS_SHORT — so the
# signature is unchanged and no caller has to be updated to get it.
pf_depth_note () {
  local sampled="${6:-0}"; case "$sampled" in ''|*[!0-9]*) sampled=0;; esac
  case "${1:-unknown}" in
    match-field)
      if [ "${2:-0}" = "${5:-0}" ]; then
        echo "**   reorder depth ${2} coded picture(s) == declared ${3} frame(s) x ${4} pictures/frame:"
        echo "**   the declaration fully ACCOUNTS for the measured depth — the SPS is CORRECT in its own"
      else
        echo "**   reorder depth ${2} coded picture(s) sits ABOVE the declared ${3} frame(s) and at or below"
        echo "**   ${3} x ${4} = ${5} pictures: the declaration ACCOUNTS for the measured depth (this window"
        echo "**   simply does not exercise all of it) — the SPS is CORRECT in its own"
      fi
      echo "**   unit and this stream conforms; nothing here needs repair. On a container that stores no DTS,"
      echo "**   ffmpeg reconstructs it with a FRAME-unit delay applied to FIELD packets — short by"
      echo "**   the field factor — so non-monotonic-DTS counts on this class measure the READER,"
      echo "**   not the source (2023 VMA class)." ;;
    match-frame)
      echo "**   reorder depth ${2} coded picture(s) == declared ${3} frame(s) (1 picture/frame) — ordinary"
      echo "**   progressive B-frame reorder, fully accounted for. One picture per frame means ffmpeg's"
      echo "**   has_b_frames delay is counted in the SAME unit as the packets, so the reconstructed DTS"
      echo "**   column is not short and needs no derivation. Nothing here needs repair." ;;
    understated)
      echo "**   reorder depth ${2} coded picture(s) EXCEEDS the declared ${3} frame(s) x ${4} pictures/frame"
      echo "**   (= ${5}): the stream presents deeper than it declares — genuinely non-conforming, a"
      echo "**   different root cause from the units defect, and worth confirming before repair." ;;
    none)
      echo "**   reorder depth ${2} coded picture(s) is within the declared ${3} frame(s) of delay — the"
      echo "**   reader's PACKET delay covers everything measured here, so no derivation is owed." ;;
    unknown)
      echo "**   reorder depth NOT classified: declared depth='${3}' pictures/frame='${4}' — one of the two"
      echo "**   is unreadable (unparseable SPS, or an essence probe that could not conclude). unknown is"
      echo "**   NOT zero and never routes as 'understated'." ;;
    *) : ;;
  esac
  # NEVER SILENT: the routing fact, printed wherever the class is printed.
  case "${3:-unknown}" in
    ''|*[!0-9]*) : ;;
    *) if [ "${2:-0}" -gt "$3" ]; then
         echo "**   PF_DTS_SHORT=yes — measured depth ${2} PACKETS exceeds the ${3}-packet delay ffmpeg"
         echo "**   applies from has_b_frames. On a reconstructed-DTS container that IS the"
         echo "**   non-monotonic-DTS generator, and the DTS column must be DERIVED, not believed."
       fi ;;
  esac
  [ "$sampled" -gt 0 ] && echo "**   (measured over $sampled timestamped picture(s) in a ${PF_SCAN_WINDOW}-packet head sample — a sample can only UNDERSTATE the depth)"
  return 0
}

# mux_confessions LOGFILE — count the muxer's own admissions that it INVENTED
# timing: "pts has no value", "Timestamps are unset in a packet", non-monotonic
# DTS nudges. Any nonzero count on a MOV mux is a HARD STOP: the video bits may
# be perfect while the written timeline is garbage (post-mortem 2026-07-25 —
# these lines were treated as cosmetic and the shipped files were unwatchable).
mux_confessions () {
  [ -f "${1:-}" ] || { echo 0; return; }
  grep -ciE 'pts has no value|timestamps are unset|non-?monotonic dts' "$1" || true
}

# mux_confessions_scoped LOGFILE [VIDEO_OUT_INDEX] — the same confession
# classes, split by the stream ffmpeg ITSELF attributes them to (1.14 / DF-10).
# The whole-log grep above hard-stopped a build over an audio DTS nudge — the
# ms-quantization class verify gate (e) already tolerates on the way in — as
# "invented VIDEO timing". The muxer says which stream each line belongs to:
#   * ffmpeg 6+ fftools tags:  [vost#0:0…  [aost#0:1…  [sost#0:2…
#   * 4.4-era libavformat:     "Non-monotonous DTS in output stream 0:1; …",
#                              "Timestamps are unset in a packet for stream 1…",
#                              "…non monotonically increasing dts to muxer in
#                               stream 1: …"   (measured on this bench, 4.4.2)
# Both shapes are matched; the 4.4 "Non-monotonous"/"non monotonically" spellings
# are counted here too (the older grep missed them entirely). A line carrying NO
# attribution ("pts has no value" is bare in both eras) counts as VIDEO — the
# conservative default: an unattributable confession keeps the hard stop.
# Prints eval-able counters:
#   MC_TOTAL=n MC_VIDEO=n MC_AUDSUB=n MC_UNATTR=n
# where MC_VIDEO includes MC_UNATTR, and MC_AUDSUB is audio+subtitle only.
# VIDEO_OUT_INDEX is the video stream's OUTPUT index (default 0 — every caller
# of this function maps its video first).
mux_confessions_scoped () {
  local log="${1:-}" vidx="${2:-0}"
  if [ ! -f "$log" ]; then echo "MC_TOTAL=0 MC_VIDEO=0 MC_AUDSUB=0 MC_UNATTR=0"; return 0; fi
  { grep -iE 'pts has no value|timestamps are unset|non-?monoton(ic|ous) dts|non monotonically increasing dts' "$log" 2>/dev/null || true; } | \
  awk -v vidx="$vidx" '
    { line=tolower($0); tot++
      if (line ~ /\[aost#/ || line ~ /\[sost#/) { aud++; next }
      if (line ~ /\[vost#/) { vid++; next }
      n=""
      if      (match(line, /in output stream [0-9]+:[0-9]+/)) { s=substr(line,RSTART,RLENGTH); sub(/.*:/,"",s); n=s }
      else if (match(line, /to muxer in stream [0-9]+/))      { s=substr(line,RSTART,RLENGTH); sub(/.*stream /,"",s); n=s }
      else if (match(line, /for stream [0-9]+/))              { s=substr(line,RSTART,RLENGTH); sub(/.*stream /,"",s); n=s }
      if (n=="") { un++; vid++; next }
      if (n+0==vidx+0) vid++; else aud++
    }
    END{ printf "MC_TOTAL=%d MC_VIDEO=%d MC_AUDSUB=%d MC_UNATTR=%d\n", tot+0, vid+0, aud+0, un+0 }'
  return 0
}

# --- probe-shaped mux failure -> ONE honest retry at a 1G window (WO 1.2) ----
# Some source will exceed ANY fixed window — the raised 200M default included,
# and the operator may have LOWERED it via RTM_PROBESIZE. When avformat opens an
# input without ever learning a stream's parameters, the mux fails with one of
# exactly two probe-shaped tells: "dimensions not set" (the MOV muxer refusing
# to write a header for a video stream whose size it never saw) or "Could not
# find codec parameters". That class is a WINDOW problem, not a source defect,
# so the mux paths (remux.sh, dual-track.sh, pairfill-paff.sh) retry exactly
# once at 1G on both axes — announcing it first — instead of hard-failing with
# no self-help. Any OTHER failure is never retried (a retry must not mask a
# genuinely different error), and a second miss keeps the exit-code contract
# (1 FAIL). One retry, no loops; the output gates downstream of the mux are
# untouched — a retry only widens how much of the source is READ during
# probing, never what is written or blessed.
FF_RETRY_OPTS=(-probesize 1G -analyzeduration 1G)

# probe_shaped_failure LOGFILE — 0 iff the mux log carries the probe-window tell.
probe_shaped_failure () {
  [ -f "${1:-}" ] || return 1
  grep -qiE 'dimensions not set|could not find codec parameters' "$1"
}

# probe_retry_notice — the single honest line announcing the retry (printed at
# most once per mux; asserted verbatim by tests/regression.d/12-probe-retry.sh).
probe_retry_notice () {
  echo "** probe window exhausted at default; retrying with 1G — consider RTM_PROBESIZE"
}

# map a measured field/coded rate to a clean rebuild-paff FIELD_RATE + TIMESCALE.
# 58-62 defaults to 60000/1001 (NTSC PAFF is far more common than true 60).
pf_suggest_field_rate () {
  awk "BEGIN{r=${1:-0}+0;
    if(r>58&&r<62) print \"60000/1001 60000\";
    else if(r>=49&&r<=51) print \"50 50000\";
    else if(r>=29&&r<31.5) print \"30000/1001 30000\";
    else if(r>=24.5&&r<28) print \"25 25000\";
    else if(r>=23&&r<24.5) print \"24000/1001 24000\";
    else print \"unknown unknown\"}"
}

# one probe pass -> KEY=VAL lines for eval. Decision logic lives ONLY here.
# WO 1.2: when the input's video PARAMETERS are invisible at the current window
# (the probe-undershoot class), stdout also carries one deliberate
# FF_INPUT_OPTS=(...) array line so the eval'ing caller's own later opens ride
# the widened window too — see the comment at the check below.
pf_detect () {
  IN="$1"
  pf_codec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  # --- probe-layer self-heal (WO 1.2): a video stream the container NAMES
  # (codec_name from the PMT/header) whose PARAMETERS never resolved (width
  # unreadable) is precisely the window-undershoot class from the lib-probe.sh
  # post-mortem — and it does not just threaten the mux: every parameter-needing
  # read downstream of this detect is equally blind (verify.sh's VCL lossless
  # arbiter hashed an EMPTY source at an undersized window and called it a
  # MISMATCH). So widen to the same 1G the mux retry uses — for the rest of THIS
  # probe pass, and, because every caller evals our stdout, for the CALLER's
  # process as well via the emitted array line (mov.sh's PR|PF whitelist drops
  # it by design; it keeps its own window). Read-only: a wider window changes
  # how much of the source is READ during probing, never what is written. The
  # note goes to stderr — stdout must stay eval-safe.
  pf_w=$(ffp -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  if [ -n "$pf_codec" ]; then
    case "${pf_w:-}" in ''|0|N/A)
      echo "   note: $pf_codec stream parameters invisible at the current probe window — re-probing wide (1G); consider RTM_PROBESIZE" >&2
      FF_INPUT_OPTS=("${FF_RETRY_OPTS[@]}")
      printf 'FF_INPUT_OPTS=(%s)\n' "${FF_RETRY_OPTS[*]}"
      ;;
    esac
  fi
  pf_field=$(ffp -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_af=$(ffp -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_rf=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  # shellcheck disable=SC2046  # word splitting is the point: "RATE TOTAL MISSING SPANRATE METHOD"
  set -- $(pf_coded_rate "$IN")
  pf_cr="${1:-0}"; pf_tot="${2:-0}"; pf_miss="${3:-0}"; pf_crspan="${4:-0}"; pf_rmeth="${5:-span}"
  pf_nf=$(pf_eval_fps "${pf_af:-0}")
  awk "BEGIN{exit !(${pf_nf:-0}>0)}" || pf_nf=$(pf_eval_fps "${pf_rf:-0}")
  pf_ratio=$(awk "BEGIN{if(${pf_nf:-0}>0)printf \"%.3f\",${pf_cr:-0}/$pf_nf; else print 0}")
  pf_frac=$(awk "BEGIN{if(${pf_tot:-0}>0)printf \"%.3f\",${pf_miss:-0}/$pf_tot; else print \"0.000\"}")
  # ~half the packets untimestamped = the PAFF pair signature (first field of each
  # pair timestamped, its mate not) — the class the timestamped-only rate misread.
  pf_half=no; awk "BEGIN{exit !(${pf_frac:-0}>=0.35 && ${pf_frac:-0}<=0.65)}" && pf_half=yes
  # --- P1.2: the ratio is tested against BOTH hypotheses -----------------------
  # pf_ratio = coded-picture rate / CONTAINER fps. The pre-P1.2 gate accepted
  # exactly one reading of that denominator — that the container declares the
  # FRAME rate, so field coding shows up as ratio ~2. mkvmerge writes one block
  # per FIELD, and then the container declares the FIELD rate: a genuinely
  # field-coded capture reads ratio ~1 and the detector said paff=no. That false
  # negative starved pf_suggest_field_rate (only consulted when pf_paff=yes) and
  # sent pairfill's first refusal gate straight to exit 3 — the 54.6 GB VMA
  # capture had no route at all.
  #   H1  container fps is the FRAME rate -> expect ratio ~2   (unchanged)
  #   H2  container fps is the FIELD rate -> expect ratio ~1 AND essence evidence
  #       that there really are 2 coded pictures per frame AND a container fps
  #       that IS a field rate (59.94 / 50); PF_FIELD_RATE is then the container
  #       fps itself.
  # ADVERSARIAL CASE, and the reason H2 is not "ratio ~1 + interlaced-looking":
  # a true 59.94p progressive sports feed gives ratio ~1 under H2 as well. The
  # discriminator is the ESSENCE probe (PF_PPF), never the ratio, and never
  # field_order (MBAFF and frame-coded interlace set that too). PF_PPF=unknown
  # therefore leaves PAFF at `no` — unknown is not yes — and the printers say so.
  # PF_RATIO_HYP records which hypothesis won so the answer is never anonymous.
  pf_ppf=$(pf_ppf_probe "$IN")
  pf_paff=no; pf_fr=unknown; pf_ts=unknown; pf_hyp=none
  if [ "$pf_codec" = h264 ]; then
    if awk "BEGIN{exit !(${pf_ratio:-0}>=1.7 && ${pf_ratio:-0}<=2.3)}"; then
      pf_paff=yes; pf_hyp=h1
      pf_sg=$(pf_suggest_field_rate "$pf_cr"); pf_fr=${pf_sg%% *}; pf_ts=${pf_sg##* }
    elif [ "$pf_ppf" = 2 ] && awk "BEGIN{exit !(${pf_ratio:-0}>=0.85 && ${pf_ratio:-0}<=1.15)}"; then
      # the container's own fps must map to a FIELD rate — reuse the one table
      # (58-62 -> 60000/1001, 49-51 -> 50) so H2 can never drift from it
      pf_sg=$(pf_suggest_field_rate "$pf_nf")
      case "${pf_sg%% *}" in
        60000/1001|50) pf_paff=yes; pf_hyp=h2; pf_fr=${pf_sg%% *}; pf_ts=${pf_sg##* };;
      esac
    fi
  fi
  printf 'PF_CODEC=%s\nPF_FIELD=%s\nPF_CODED_RATE=%s\nPF_CODED_RATE_SPAN=%s\nPF_RATE_METHOD=%s\nPF_NOMINAL_FPS=%s\nPF_RATIO=%s\nPF_RATIO_HYP=%s\nPF_PPF=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\nPF_NOPTS=%s\nPF_NOPTS_FRAC=%s\nPF_HALF_TS=%s\n' \
    "${pf_codec:-na}" "${pf_field:-na}" "${pf_cr:-0}" "${pf_crspan:-0}" "${pf_rmeth:-span}" \
    "${pf_nf:-0}" "${pf_ratio:-0}" "$pf_hyp" "$pf_ppf" "$pf_paff" "$pf_fr" "$pf_ts" \
    "${pf_miss:-0}" "${pf_frac:-0}" "$pf_half"
}

# pf_hyp_note HYP RATIO PPF NOMINAL_FPS FIELD_RATE — the one human announcement
# of which ratio hypothesis won (or why neither did), shared by probe.sh and
# diagnose.sh so the two can never tell different stories.
pf_hyp_note () {
  case "${1:-none}" in
    h1) echo "**   hypothesis H1 WINS: the container's ${4}/s is the FRAME rate and the coded-picture"
        echo "**   rate runs ~2x it (ratio ${2}) — the classic field-coded signature." ;;
    h2) echo "**   hypothesis H2 WINS: ratio ${2} (~1x), but the ESSENCE probe measured ${3} coded"
        echo "**   pictures per frame — so the container's ${4}/s is the FIELD rate (one block per"
        echo "**   field, the mkvmerge shape), not the frame rate. Field rate = ${5}."
        echo "**   field_order is corroborative only here; the decode count is what decided it." ;;
    *)  case "${3:-unknown}" in
          unknown) echo "**   H2 (container declares the FIELD rate) tested and NOT accepted: the essence probe"
                   echo "**   could not measure pictures-per-frame (PF_PPF=unknown). unknown is not yes — a true"
                   echo "**   59.94p progressive feed shows the same ~1x ratio, so the ratio alone may never"
                   echo "**   decide this. paff stays no." ;;
          1)       echo "**   H2 (container declares the FIELD rate) tested and REJECTED: the essence probe"
                   echo "**   measured 1 coded picture per frame, so ratio ${2} really is 1x. Neither hypothesis"
                   echo "**   fires; paff=no on measured evidence, not on the ratio alone." ;;
          *)       : ;;
        esac ;;
  esac
  return 0
}

# disc_scan — forward-timestamp-gap (discontinuity) scan of the video track.
# A discontinuity is a FORWARD DTS jump larger than a frame: the capture dropped
# frames and the broadcast clock skipped ahead. Stream-copy preserves these jumps
# in the video timeline but COLLAPSES them in raw PCM audio (ffmpeg's muxer
# writes no mid-stream empty edit per drop — QTFF has the mechanism, the writer
# doesn't use it), so a blind `-c copy` of a discontinuous source slides the
# audio progressively out of sync (see the remux-sync post-mortem). This is distinct from MISSING or BACKWARD timestamps:
# the timestamps here are present AND monotonic, so the mux tests pass — the gap
# is forward, and only a delta scan finds it. NO decode; whole stream (a gap can
# sit anywhere in a long capture, so this is deliberately not window-bounded).
#
# Usage:  eval "$(disc_scan INPUT)"
#   -> DISC_COUNT (forward gaps) DISC_MISSING (s of dropped time) DISC_FIRST (s|na)
#      DISC_FRAMEDUR (s) DISC_BACK (backward DTS steps) DISC_DUP (duplicate DTS)
#      DISC_NA (packets with no DTS) DISC_P_NA (packets with no PTS)
#      DISC_P_COUNT / DISC_P_MISSING / DISC_P_FIRST / DISC_P_FRAMEDUR
#        (the same census taken in PRESENTATION order — see below)
# DISC_BACK/DISC_DUP are the WHOLE-FILE DTS-rot counters the backhaul gate needs:
# the windowed scan read 0 on the 2009 and 2012 feeds whose defects sat mid-file
# at splice points, and the decode-to-null nmono warnings come from exactly these
# demux-visible DTS relations — so one demux pass answers both the gap and the
# rot question without a decode.
#
# --- P1.4: WHY there are now two arms ----------------------------------------
# The coded-order arm measures adjacent dts_time deltas. Two things are wrong
# with using that as a TIMELINE claim:
#   1. On a container that stores no DTS (Matroska, raw ES) the dts column is
#      ffmpeg's reconstruction — so on the field-coded/units class the metric
#      measures the bug with the bug. INCIDENT TESTIMONY, not a local
#      measurement (the 54.6 GB 2023 VMA capture is not on this machine and
#      cannot be re-measured here): ~5,475 s reported "dropped" out of a
#      10,944 s program, against a real loss of 4.58 s — a ~1,000x
#      overstatement. The MECHANISM is what the two arms below are pinned on,
#      and that is reproducible in the suite on constructed shapes.
#   2. It skips N/A rows silently, so a hole in the timestamps becomes a delta
#      that spans the hole — a phantom gap manufactured out of missing data.
# And the number was not merely reported: FOUR consumers spend DISC_MISSING as a
# TOLERANCE BUDGET (verify gate (f), verify --silence, diagnose's dropped-time
# claim, backhaul_gate's trigger), so an inflated figure WIDENS acceptance —
# the most dangerous direction a wrong measurement can point.
# So the presentation arm sorts the PTS column numerically and deltas THAT (the
# same `sort -n` discipline verify gate (e) already uses on keyframe times), and
# the four consumers read the presentation fields. The coded-order fields are
# untouched and still printed: DISC_BACK/DISC_DUP are DTS-rot counters and
# coded order is their correct order.
# NOTE THE DIRECTION: this NARROWS tolerances. A real desync that used to hide
# inside a phantom budget will now correctly fail. That is the fix working — and
# a genuinely gappy source still widens gate (f) by its REAL measured loss.
#
# Tunables: DISC_MULT (gap threshold in frame durations, default 1.5).
# Test hook: DISC_DTS_FILE bypasses ffprobe. It accepts EITHER the historical
#   one-column list of dts_time values (the presentation arm then reads that same
#   column, sorted — the best available answer for a DTS-only injection) or
#   two-column "pts_time,dts_time" lines, which is what the real probe now reads.
#   DISC_FRAMEDUR_IN=<s> supplies the frame duration for the injected list.
disc_scan () {
  local IN="${1:-}" mult="${DISC_MULT:-1.5}" ts fdur rf
  if [ -n "${DISC_DTS_FILE:-}" ]; then
    ts=$(cat "$DISC_DTS_FILE"); fdur="${DISC_FRAMEDUR_IN:-0}"
  else
    rf=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
    fdur=$(pf_eval_fps "${rf:-0}")
    fdur=$(awk "BEGIN{f=${fdur:-0}+0; if(f>0) printf \"%.6f\",1/f; else print 0}")
    ts=$(ffp -v error -select_streams v:0 -show_entries packet=pts_time,dts_time -of csv=p=0 "$IN" 2>/dev/null)
  fi
  # arm 1 — CODED order, dts column. Byte-for-byte the pre-P1.4 census; only the
  # column addressing changed (a one-column injected list still reads as dts).
  printf '%s\n' "$ts" | awk -F, -v fdur="${fdur:-0}" -v mult="$mult" '
    NF{ pv=$1; t=$2; if(t=="") t=$1
        if(pv=="N/A"||pv=="") pna++
        if(t=="N/A"||t=="") { dna++; next }
        t=t+0
        if(seen){ d=t-p; if(d>0){ nd++; dl[nd]=d; pos[nd]=p; sd+=d } else if(d<0){ bk++ } else { du++ } }
        p=t; seen=1 }
    END{
      if(nd<1){ print "DISC_COUNT=0\nDISC_MISSING=0.000\nDISC_FIRST=na"
                printf "DISC_FRAMEDUR=%.6f\nDISC_BACK=%d\nDISC_DUP=%d\nDISC_NA=%d\nDISC_P_NA=%d\n", fdur+0, bk+0, du+0, dna+0, pna+0
                exit }
      fd=fdur+0; if(fd<=0) fd=sd/nd            # no fps -> mean delta is an excellent CFR proxy
      thr=mult*fd; cnt=0; miss=0; first="na"
      for(i=1;i<=nd;i++) if(dl[i]>thr){ cnt++; miss+=dl[i]-fd; if(first=="na") first=sprintf("%.3f",pos[i]) }
      printf "DISC_COUNT=%d\nDISC_MISSING=%.3f\nDISC_FIRST=%s\nDISC_FRAMEDUR=%.6f\nDISC_BACK=%d\nDISC_DUP=%d\nDISC_NA=%d\nDISC_P_NA=%d\n", cnt, miss, first, fd, bk+0, du+0, dna+0, pna+0
    }'
  # arm 2 — PRESENTATION order: the pts column, sorted numerically, then deltaed.
  # This is the arm whose seconds are a claim about the PROGRAM's timeline.
  printf '%s\n' "$ts" | awk -F, 'NF{ p=$1; if(p=="N/A"||p=="") next; printf "%.6f\n", p+0 }' | \
    LC_ALL=C sort -n | \
    awk -v fdur="${fdur:-0}" -v mult="$mult" '
      { t=$1+0
        if(seen){ d=t-p; if(d>0){ nd++; dl[nd]=d; pos[nd]=p; sd+=d } }
        p=t; seen=1 }
      END{
        if(nd<1){ printf "DISC_P_COUNT=0\nDISC_P_MISSING=0.000\nDISC_P_FIRST=na\nDISC_P_FRAMEDUR=%.6f\n", fdur+0; exit }
        fd=fdur+0; if(fd<=0) fd=sd/nd
        thr=mult*fd; cnt=0; miss=0; first="na"
        for(i=1;i<=nd;i++) if(dl[i]>thr){ cnt++; miss+=dl[i]-fd; if(first=="na") first=sprintf("%.3f",pos[i]) }
        printf "DISC_P_COUNT=%d\nDISC_P_MISSING=%.3f\nDISC_P_FIRST=%s\nDISC_P_FRAMEDUR=%.6f\n", cnt, miss, first, fd
      }'
}

# disc_budget_guard — the ts-health V_NADTS discipline, ported (P1.4) to every
# consumer that spends the gap census as a TOLERANCE BUDGET.
# A gap count measured across missing timestamps is measured across holes: the
# deltas span them, so the count is inflated and the seconds are phantom. Spent
# as a budget, a phantom number WIDENS acceptance — so on any missing-PTS
# finding the budget is 0 and the reason is announced, never a silent widening.
# Split in two so a caller can take the number without the prose (and print the
# prose exactly where its own report wants it): disc_budget_secs echoes the
# spendable seconds, disc_budget_note prints the one explanation.
disc_budget_secs () {   # disc_budget_secs P_NA P_MISSING -> the spendable seconds
  case "${1:-0}" in ''|*[!0-9]*) printf '0'; return 0;; esac
  [ "${1:-0}" -gt 0 ] && { printf '0'; return 0; }
  printf '%s' "${2:-0}"
}
disc_budget_note () {   # disc_budget_note P_NA P_COUNT — one line, or nothing
  case "${1:-0}" in ''|*[!0-9]*) return 0;; esac
  [ "${1:-0}" -gt 0 ] || return 0
  echo "   gap census measured ACROSS ${1} packet(s) with no PTS — the deltas span the holes, so"
  echo "   the ${2:-0} apparent gap(s) are unreliable and buy NO tolerance (budget 0). Repair the"
  echo "   missing timestamps first (diagnose.sh), then re-measure."
  return 0
}

# --- WO 4.1: the 4:2:2 arm, demoted from refusal to empirical proof ----------
# The 1.8.0–1.10.0 gate refused mpeg2video/h264 + yuv422p outright (exit 11,
# nothing built), claiming "AVFoundation/QuickTime cannot decode 4:2:2".
# FALSIFIED on the bench 2026-08-13 (macOS 26.6.1, ffmpeg 8.1.2): every refused
# class fully decodes — qlmanage thumbnail AND avconvert whole-file (50/50
# frames) — MPEG-2 4:2:2, H.264 High 4:2:2, 10-bit 4:2:2, 10-bit 4:4:4, HEVC
# Rext 4:2:2. Worse, the exact 8-bit predicate [ pix = yuv422p ] let the
# ACTUAL 10-bit contribution profiles (yuv422p10le — the AVC-Intra class)
# bypass the gate entirely: over-broad and under-broad at once, and the cost
# of being wrong was the whole deliverable. The reform follows the plugin's
# own doctrine — prove, don't guess — and its own recorded fact that decode
# support DRIFTS by macOS version (C63: Tahoe 26.4 dropped MJPEG variants/
# AIC): a hardcoded codec verdict rots, a per-file post-build check
# self-corrects. Being wrong now costs an artifact plus an honest REVIEW,
# never "no artifact at all". Caveat carried from the bench: the falsifying
# clips were synthetic — they disprove the categorical "cannot decode", not
# every real broadcast master; that residual is exactly WHY the check is
# per-file (playability_verdict below, driven post-build by mov.sh/auto.sh).

# qt_contribution_profile PIX_FMT — 0 iff the pix_fmt is the 4:2:2
# contribution/backhaul class, ANY bit depth (yuv422p, yuv422p10le, ...).
# The single predicate mov.sh's front door and backhaul_gate both consult.
qt_contribution_profile () { case "${1:-}" in yuv422p*) return 0;; *) return 1;; esac; }

# contribution_advisory VCODEC PIX_FMT — the one announcement, shared by the
# mov.sh front door and backhaul_gate so the two can never diverge. The first
# line's phrase is pinned by tests/regression.d/41-422-empirical.sh.
contribution_advisory () {
  echo "** contribution profile ${1:-?}/${2:-?} — playability will be verified post-build"
  echo "   (the categorical 4:2:2 refusal was falsified on macOS 26.6.1, 2026-08-13;"
  echo "    decode support drifts by macOS version, so the driver PROVES this build"
  echo "    with playable-check.sh once it exists. On a standalone builder run,"
  echo "    prove it yourself: scripts/playable-check.sh OUT.mov)"
  echo "    (4:2:2 contribution class: add --fidelity — renders ≠ renders correctly, 2026-08-15)"
}

# playability_verdict OUTPUT.mov [--fidelity] — the empirical half of the
# demoted gate: run playable-check.sh on a FINISHED build (passing the optional
# flag straight through), print its output indented plus the additive machine
# line
#     MOV_PLAYABILITY os=<ver|na> verdict=<ok|fail|skip> fidelity=<ok|fail|skip>
# (os= and verdict= are byte-for-byte the WO 4.1 fields; fidelity= is APPENDED,
# WO-B 2026-08-15 — parsed from the child's PLAYCHECK_FIDELITY line, `skip`
# when the mode was not requested or the child could not measure) and set
# PLAY_VERDICT for the caller's exit-code mapping (contribution-profile
# fail/skip -> 10 REVIEW at the driver; never 11, never 1 — the artifact exists
# and its essence verified). A fidelity fail needs no separate mapping: the
# child exits 1, which the existing case below already maps to fail. REUSES
# playable-check.sh (Ground Rule 6: the verdict self-dates the macOS it ran on)
# — never forks its logic. Returns 0 always: the VERDICT is the result; the
# function itself must not trip set -e.
playability_verdict () {
  local out="${1:?playability_verdict needs OUTPUT}" fmode="${2:-}" prc=0 po osv fid
  if [ -n "$fmode" ]; then
    po=$(bash "$PF_LIB_DIR/playable-check.sh" "$fmode" "$out" 2>&1) || prc=$?
  else
    po=$(bash "$PF_LIB_DIR/playable-check.sh" "$out" 2>&1) || prc=$?
  fi
  printf '%s\n' "$po" | sed 's/^/   /'
  osv=$(sw_vers -productVersion 2>/dev/null || echo na)
  case "$prc" in 0) PLAY_VERDICT=ok;; 3) PLAY_VERDICT=skip;; *) PLAY_VERDICT=fail;; esac
  fid=$(printf '%s\n' "$po" | sed -n 's/^PLAYCHECK_FIDELITY verdict=\([a-z]*\).*/\1/p' | awk 'NR==1')
  echo "MOV_PLAYABILITY os=${osv:-na} verdict=$PLAY_VERDICT fidelity=${fid:-skip}"   # machine-readable (additive, WO 4.1; fidelity= appended WO-B)
  return 0
}

# --- backhaul_gate — enforced at EVERY .mov entry point -----------------------
# backhaul_gate INPUT [VCODEC] [PIX_FMT] [CONTAINER]
# mov.sh runs the verbose front-door pass; this is the SAME verdict at the
# choke points that actually write a .mov (auto.sh, remux.sh, rebuild-paff.sh,
# pairfill-paff.sh), so no route — batch.sh and direct script calls included —
# can diverge from the criteria (the pre-gate 2017-feed build proved the
# bypass was real). Since WO 4.1/4.2 the gate refuses NOTHING — it announces:
#   * 4:2:2 contribution profile -> ADVISORY only (contribution_advisory);
#     the verdict is empirical and belongs AFTER the build. Nothing refuses
#     on pix_fmt anywhere anymore — the 1.10.0 "no side door" property
#     inverts for this arm: no side door REFUSES either.
#   * timeline rot (mpegts/mpeg2video gaps + non-monotonic DTS) -> WARNING
#     (WO 4.2, demoted from the 1.8.0-1.10.0 refusal): the old exit-11
#     claimed "no lossless MOV of this class survives verify" — a
#     PREDICTION, while the plugin already owns the measured judges: the
#     mux-confession hard stop (invented timing, KEPT — that one is
#     measured) and verify.sh's post-build timeline gates. On the
#     constructed rot fixture the prediction was wrong twice over (bench
#     2026-08-14): the demuxer's own discontinuity fixup muxed a monotonic
#     timeline (no confession fired), and verify caught the REAL defect
#     (dual-track access misalignment -> REVIEW) — an artifact plus
#     evidence instead of "no artifact at all". The warning keeps the
#     refusal's full voice: same three routes, same scan evidence, plus the
#     additive MOV_ROT_WARN machine line.
# Missing args are probed (instant single-field ffprobe; the rot scan only
# ever runs for mpegts/mpeg2video).
#
# Protocol: a caller that already passed the gate exports RTM_BACKHAUL_GATED=1
# so children skip the re-check; RTM_FORCE_BACKHAUL=1 (mov.sh --force-backhaul)
# says the operator has decided already. Both are API, and BOTH SHORT-CIRCUIT
# THE WHOLE FUNCTION — the 4:2:2 contribution advisory included, because the
# early returns sit above it. Stated plainly because the previous note here
# claimed the opposite ("both are no-ops for the pix_fmt arm"), and it is not
# what the code does: with RTM_FORCE_BACKHAUL=1 a direct
# `remux.sh <4:2:2 source>` prints NO contribution advisory at all.
# What IS true is the narrower statement about mov.sh's FRONT DOOR: mov.sh
# prints the advisory itself, before and independently of this gate, and does
# not condition it on --force-backhaul — so on /mov the flag really does leave
# the pix_fmt arm untouched. Nothing refuses on pix_fmt anywhere either way;
# the flags change what is ANNOUNCED at the child entry points, not what is
# built. (Comment corrected, not the control flow: changing these returns
# would change behavior at four .mov-writing entry points, which is a design
# decision and not this round's business.)
backhaul_gate_routes () {
  echo "   Honest routes out (the source stays TS/MKV — health-checked, never doomed):"
  echo "     keep     the source as-is — it is already the archival master; prove its"
  echo "              health: scripts/ts-health.sh SOURCE  (transport, timestamps, seek)"
  echo "     playback ffmpeg -i SOURCE -map 0:v:0 -map '0:a?' -c copy OUT.mkv  (lossless;"
  echo "              plays in IINA/VLC/mpv) — then scripts/ts-health.sh OUT.mkv to prove"
  echo "              the copy's timeline survived intact"
  echo "     mp4swap  scripts/mp4-swap.sh SOURCE — lossless CONTAINER swap (same bitstream,"
  echo "              .mp4, sample entry mp4v+esds): the rung between a retag and a"
  echo "              re-encode. Measured 2026-08-15 on an MPEG-2 4:2:2 capture QuickTime"
  echo "              destroyed as .mov — SSIM 0.9175+ on the same timestamps as .mp4"
  echo "     rung4    scripts/rung4.sh — operator-attested re-encode, the LAST route (the"
  echo "              only one that stops being lossless)"
  echo "   Skip this scan+warning: mov.sh --force-backhaul (sets RTM_FORCE_BACKHAUL=1)"
}
# --- WO 5.2 unroutable codecs — shared classifiers + refusal voice ------------
# (moved here from mov.sh in the 1.11 fix round, 2026-08-14): the reviewer
# proved the gate-at-every-entry-point standard (1.10.0's own bar) was broken —
# a DIRECT auto.sh run burned rungs 0->2->3 and died in the raw muxer stack
# trace, remux.sh littered a 0-byte .part behind "vp9 only supported in MP4",
# and batch.sh recorded the class FAIL instead of REFUSED. One classifier +
# one refusal voice here; mov.sh, auto.sh and remux.sh all dispatch on it, so
# no entry point can diverge again. The regression suite unit-pins the
# classifiers through mov.sh's RTM_TEST sourcing guard (mov.sh sources this
# lib before the guard).
#
# unroutable_v: video codecs NO .mov can carry — the mux itself is impossible,
# so no lossless MOV of the class exists and the gate refuses with the routes
# instead of letting the muxer die raw (WO 5.2). VC-1 has no MOV sample entry
# (raw form: "Could not find tag for codec vc1"); VP9/AV1 the MOV muxer
# rejects outright (raw form: "vp9 only supported in MP4" — bench-verified
# ffmpeg 9.0.1, 2026-08-14; MP4 takes both -c copy). Distinct from the
# PR_VNATIVE=no class (ffv1 etc.): those MUX and get the WO 4.1 post-build
# playability proof — these never reach a mux at all.
unroutable_v () { case "$1" in vc1|vp9|av1) return 0;; *) return 1;; esac; }
# unroutable_a: audio whose "PCM treatment" is garbage, not a render — Dolby E
# is a broadcast mezzanine (up to 8 programs per AES3 pair); decoding it is a
# program/channel-assignment EDITORIAL decision, so the specialist decode is a
# named, operator-invoked step, never automatic (WO 5.2). Note the limit: this
# matches the codec-tagged form (codec_name dolby_e) only — Dolby E hiding
# inside a PCM track (SMPTE 337M / AES3 wrapping) is NOT sniffed (payload
# sync-word inspection is the deep-inspection rabbit hole); that named
# limitation is documented in SKILL.md troubleshooting.
unroutable_a () { case "$1" in dolby_e) return 0;; *) return 1;; esac; }

# unroutable_v_refuse CODEC — the one honest refusal, REFUSED-class outcome:
# the caller prints nothing else and exits 11. Nothing written, source
# untouched — because unlike every other gate the failure is not a playability
# question the post-build proof can answer: the MOV cannot exist.
unroutable_v_refuse () {
  case "$1" in
    vc1)
      echo "** REFUSED: VC-1 video (the Blu-ray/HD-DVD codec) cannot be carried in a"
      echo "   .mov — the MOV muxer has no VC-1 sample entry, so a lossless MOV of this"
      echo "   source does not exist. Nothing was built; the source is untouched." ;;
    *)
      echo "** REFUSED: $1 video cannot be muxed into a .mov — the MOV muxer"
      echo "   rejects it (MP4-only carriage; bench-verified ffmpeg 9.0.1, 2026-08-14),"
      echo "   so a lossless MOV of this source does not exist. Nothing was built; the"
      echo "   source is untouched." ;;
  esac
  echo "   Honest routes out:"
  echo "     keep   the source as-is — it is already the archival master"
  echo "     remux  lossless container change for playback (no re-encode):"
  echo "            VP9/AV1: ffmpeg -i IN -c copy OUT.mp4;  VC-1: ffmpeg -i IN -c copy"
  echo "            OUT.mkv  (plays in IINA/VLC/mpv either way)"
  echo "     rung4  scripts/rung4.sh — operator-attested re-encode, the ONLY sanctioned"
  echo "            path to a QuickTime-native .mov of this class"
  echo "MOV_REFUSED profile=unroutable-vcodec vcodec=$1"   # machine-readable (additive, WO 5.2)
}

# unroutable_a_refuse ORD — the Dolby E refusal; caller exits 11. The exclude
# route names the flag-bearing entry points (mov.sh/remux.sh --audio-keep);
# auto.sh has no keep flag, so its route out IS one of those two.
unroutable_a_refuse () {
  echo "** REFUSED: audio track a:$1 is Dolby E — a broadcast mezzanine carrying"
  echo "   up to 8 programs in one AES3 pair. MOV cannot carry the bitstream, and"
  echo "   treating it as PCM yields FULL-SCALE NOISE, not audio. Which program and"
  echo "   channel assignment to extract is an editorial decision, so the decode is a"
  echo "   named, operator-invoked step — never automatic. Nothing was built."
  echo "   Honest routes out:"
  echo "     decode   specialist decode via ffmpeg's dolby_e decoder (operator-invoked):"
  echo "              ffmpeg -i IN -map 0:a:$1 -c:a pcm_s24le program.wav"
  echo "              (first program by default) — then marry the WAV back in post,"
  echo "              or rerun mov.sh on a source carrying the decoded track"
  echo "     exclude  rerun with --audio-keep IDX[,IDX] (mov.sh / remux.sh) listing"
  echo "              only the non-Dolby-E track ordinals (the drop is announced,"
  echo "              never silent)"
  echo "     keep     the source as-is — it is already the archival master"
  echo "MOV_REFUSED profile=dolby-e-audio track=a:$1"   # machine-readable (additive, WO 5.2)
}

# backhaul_rot_warn INPUT VCODEC [CONTAINER] — THE timeline-rot arm. ONE
# implementation, ONE MOV_ROT_WARN schema, every entry point (F1, 2026-08-16).
# It used to be two: this one, and an inline copy in mov.sh that still triggered
# on the CODED-order DISC_COUNT, still claimed the coded-order seconds as
# "dropped", and emitted a MOV_ROT_WARN line without the disc_p= / disc_p_na=
# fields. Worse, mov.sh exports RTM_BACKHAUL_GATED=1, on which backhaul_gate
# returns early — so on /mov, the PRIMARY entry point, the copy was the only one
# that ever ran and the P1.4 presentation census was dead code. Measured on
# tests/fixtures/rot.ts: coded 1 gap / 17.960 s, presentation 2 gaps / 15.960 s
# — two different triggers and two different numbers under one line name.
#
# Split out of backhaul_gate rather than folded into it because mov.sh must NOT
# call backhaul_gate whole: (a) mov.sh's own 4:2:2 arm sets PLAYCHECK_DUE and
# would double-print contribution_advisory, and (b) backhaul_gate returns early
# on RTM_FORCE_BACKHAUL for BOTH arms — the contribution advisory included. On
# /mov the flag does NOT currently silence that advisory, because mov.sh prints
# it itself at its front door, before and independently of this gate: measured
# 2026-08-16 on tests/fixtures/h264_422.ts, `mov.sh IN OUT` and
# `mov.sh IN OUT --force-backhaul` both print it (2 lines each). Routing mov.sh
# through backhaul_gate would take that away. (This reason stands on the
# measurement, NOT on the retired "--force-backhaul is a no-op for the pix_fmt
# arm" claim, which the note above backhaul_gate_routes itself corrects: on a
# standalone remux.sh the flag silences the advisory outright — measured, 1 line
# plain vs 0 forced, and the same 1 -> 0 on dual-track.sh.) So the ROT arm — the
# thing that diverged — is the shared unit, and there is exactly one of it.
#
# eval's the disc_scan into the CALLER's shell (DISC_* are deliberately global)
# so a caller with its own voice can print from the SAME scan without re-running
# it. Returns 0 iff it WARNED; 1 when the class does not apply or the scan was
# clear — that is how mov.sh knows to print its "scan clear" line.
backhaul_rot_warn () {
  local in="${1:?backhaul_rot_warn needs INPUT}" vc="${2:-}" cont="${3:-}"
  [ "$vc" = mpeg2video ] || return 1
  if [ -z "$cont" ]; then
    cont=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
  fi
  case "$cont" in *mpegts*) : ;; *) return 1;; esac
  eval "$(disc_scan "$in")"
  # P1.4: the gap half of the trigger reads the PRESENTATION census — the
  # coded-order count is a dts-column artifact wherever the dts column is
  # reconstructed, and this gate's forward-gap claim is a claim about the
  # PROGRAM's timeline. The rot half (back/dup) stays coded-order: that is
  # its correct order. Both raw numbers still print.
  [ "${DISC_P_COUNT:-0}" -ge 1 ] && [ $(( ${DISC_BACK:-0} + ${DISC_DUP:-0} )) -ge 1 ] || return 1
  # WO 4.2: warn, don't refuse — the demoted gate keeps its voice (same
  # three routes) but the verdict belongs to the build's own measured
  # gates: mux-confession hard stop + verify. Never MOV_REFUSED here —
  # nothing may print a refusal and then build anyway.
  echo "** WARN: BACKHAUL TIMELINE ROT — ${DISC_P_COUNT} forward gap(s) in presentation order"
  echo "   (~${DISC_P_MISSING:-0}s dropped, first @ ${DISC_P_FIRST:-na}s; coded-order census for"
  echo "   comparison: ${DISC_COUNT:-0} gap(s), ~${DISC_MISSING:-0}s) PLUS non-monotonic"
  echo "   DTS (whole-file: backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}). Building anyway (WO 4.2):"
  echo "   the mux-confession gate hard-stops if the muxer invents timing, and verify"
  echo "   judges the finished timeline with evidence — expect REVIEW/FAIL on this"
  echo "   class. Full read: scripts/diagnose.sh SOURCE."
  disc_budget_note "${DISC_P_NA:-0}" "${DISC_P_COUNT:-0}"
  backhaul_gate_routes
  # disc= keeps its ORIGINAL coded-order meaning (append-only API: a field
  # never changes what it counts); the presentation census that actually
  # armed this warning is the APPENDED disc_p=.
  echo "MOV_ROT_WARN profile=timeline-rot vcodec=$vc disc=${DISC_COUNT:-0} back=${DISC_BACK:-0} dup=${DISC_DUP:-0} disc_p=${DISC_P_COUNT:-0} disc_p_na=${DISC_P_NA:-0}"   # machine-readable (additive, WO 4.2; disc_p*/P1.4)
  return 0
}

backhaul_gate () {
  local in="${1:?backhaul_gate needs INPUT}" vc="${2:-}" pix="${3:-}" cont="${4:-}"
  [ "${RTM_BACKHAUL_GATED:-0}" = 1 ] && return 0
  [ "${RTM_FORCE_BACKHAUL:-0}" = 1 ] && return 0
  if [ -z "$vc" ]; then
    vc=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
  fi
  if [ -z "$pix" ]; then
    pix=$(ffp -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
  fi
  # 4:2:2 arm (WO 4.1): advisory only — matches yuv422p* at every bit depth
  # (the old exact 8-bit match let yuv422p10le sources slip through unannounced).
  # The playability verdict is empirical and runs post-build in the drivers.
  if qt_contribution_profile "$pix"; then
    contribution_advisory "$vc" "$pix"
  fi
  # the rot arm lives in backhaul_rot_warn — one implementation for this gate
  # and for mov.sh's front door (F1). Its verdict is advisory here as it is
  # there: warn and continue, never refuse.
  backhaul_rot_warn "$in" "$vc" "$cont" || true
  return 0
}

# --- displaced-timestamp junction support (pairfill widening, 2026-08-18) -----
# The measured class (PROVENANCE record 2026-08-18: 23.7 GB PAFF H.264 mpegts,
# 1080i25, 451,071 coded pictures): a pair-timestamped PAFF capture where at a
# few junctions the PES timestamp rides the SECOND field of a pair instead of
# the first — a run of exactly TWO untimestamped packets, nothing missing, no
# clock jump. pairfill-paff.sh consumes the three helpers below; they live here
# because probe/diagnose share this lib and the suite unit-pins each one
# hermetically (canned-input hooks, house style).

# pf_setts_probe EXPR — 0 iff the RUNNING ffmpeg's setts accepts EXPR as a pts
# expression. The junction fill needs the NEXT_PTS/NEXT_DTS and PREV_IN*
# expression variables, which old ffmpeg (4.4 measured on this sandbox) rejects
# at option-parse time — the probe is a tiny fully-synthetic invocation (lavfi
# null audio, ~0.02 s), never a read of the operator's file.
# Test hook: PF_SETTS_OK=yes|no bypasses the probe (pins the refusal/accept
# paths on benches whose ffmpeg cannot exercise the other half).
pf_setts_probe () {
  case "${PF_SETTS_OK:-}" in yes) return 0;; no) return 1;; esac
  ffmpeg -nostdin -v error -f lavfi -i anullsrc=r=8000:cl=mono -t 0.02 \
    -c:a pcm_s16le -bsf:a "setts=pts=${1:?pf_setts_probe needs EXPR}" \
    -f null - >/dev/null 2>&1
}

# pf_trace_census INPUT — whole-file trace_headers census of the video track:
# coded pictures (first_mb_in_slice==0), field/frame split (field_pic_flag),
# and the pic_struct histogram from pic_timing SEI. Demux + header parse only,
# no decode; the video bits are never touched. Emits eval-able lines:
#   PC_PICS=n PC_FIELDS=n PC_FRAMES=n PC_STRUCT_BAD=n PC_STRUCT_HIST=k:v,...
#   PC_OK=yes|no
# PC_FRAMES = pictures whose field_pic_flag is 0 OR absent (a progressive SPS
# codes no field_pic_flag at all — those pictures are frame pictures).
# PC_STRUCT_BAD counts pic_struct values in {0,5,6,7,8} — frame/repeat/doubling
# structs that break the uniform field cadence the junction fill assumes (the
# operator's WARNING on the 2026-08-18 record). PC_STRUCT_HIST is `none` when
# the stream carries no pic_timing pic_struct at all.
# PC_OK=no (zero pictures parsed) = trace_headers unusable on this ffmpeg/file.
# Test hook: PF_TRACE_FILE=<canned trace_headers log> bypasses ffmpeg.
pf_trace_census () {
  { if [ -n "${PF_TRACE_FILE:-}" ]; then cat "$PF_TRACE_FILE"; else
      ffmpeg -nostdin -hide_banner -nostats ${FF_INPUT_OPTS[@]+"${FF_INPUT_OPTS[@]}"} \
        -i "${1:?pf_trace_census needs INPUT}" -map 0:v:0 -c copy \
        -bsf:v trace_headers -f null - 2>&1; fi; } | \
  awk '
    { name=""
      for(i=1;i<=NF;i++) if($i=="first_mb_in_slice"||$i=="field_pic_flag"||$i=="pic_struct"){ name=$i; break }
      if(name=="") next
      v=$NF+0
      if(name=="first_mb_in_slice"){ if(v==0){ pics++; pend=1 }; next }
      if(name=="field_pic_flag"){ if(pend){ pend=0; if(v==1) fields++ }; next }
      # pic_struct (exact token — pic_struct_present_flag never matches here)
      hist[v]++; nps++
      if(v==0||v==5||v==6||v==7||v==8) bad++
    }
    END{
      hs=""; for(k=0;k<=15;k++) if(hist[k]>0) hs=hs (hs==""?"":",") k ":" hist[k]
      if(nps+0==0) hs="none"
      printf "PC_PICS=%d\nPC_FIELDS=%d\nPC_FRAMES=%d\nPC_STRUCT_BAD=%d\nPC_STRUCT_HIST=%s\nPC_OK=%s\n", \
        pics+0, fields+0, pics-fields, bad+0, hs, (pics+0>0?"yes":"no")
    }'
}

# pf_poc_lattice TABLE_FILE [MAX_POC_LSB] — the POC-lattice output gate's
# checker (the record call it local gate 2: the strongest correctness evidence
# for a field fill). TABLE_FILE carries one line per coded picture, DECODE
# order: "idr,poc,pts" (idr 1|0, poc = pic_order_cnt_lsb, pts in stream
# ticks). pic_order_cnt_lsb is POC MODULO MaxPicOrderCntLsb, so each sequence
# is first UNWRAPPED to full POC per ITU-T H.264 §8.2.1.1 (PicOrderCntMsb
# steps by MaxPicOrderCntLsb on a half-range jump between consecutive
# pictures; msb resets at the IDR that heads the sequence). MAX_POC_LSB is the
# SPS-derived 2^(log2_max_pic_order_cnt_lsb_minus4+4) — prefer passing it;
# when absent/0 it is inferred per sequence as the next power of two above the
# largest observed lsb (floor 16, the spec minimum — inference is only exact
# when the stream uses its full lsb range, which a wrapping sequence does by
# construction). Then per IDR-delimited sequence the presentation lattice is
# PTS = base + POC * half_interval ; the half interval is FIT from the first
# pictures of the sequence (first pair with distinct POC whose PTS delta / POC
# delta is a positive integer) and base from the sequence's first picture,
# then EVERY picture must sit on its slot. A sequence whose half interval
# cannot be fit counts every picture off-lattice (never bless unproven); a
# single-picture sequence is trivially on-slot.
# PROVENANCE (1.15.2 Defect D): the shipped 1.14.0–1.15.1 function never
# unwrapped — git shows the unwrap never existed in the repo, so the recorded
# 2026-08-18 proving job (451,071/451,071 on-slot) ran a pre-extraction gate.
# On broadcast long-IDR open-GOP (the field source: MaxPicOrderCntLsb 512,
# 24 IDR sequences of ~18,795 pictures ≈ 73 wraps each) the un-unwrapped fit
# false-FAILed a provably correct build at 3,179/451,071 — the survivors being
# each sequence's pre-first-wrap head, exactly the wrap arithmetic. The
# unwrapped gate restores 451,071/451,071 on the same artifact and still
# fails a genuinely off-slot picture (test 76's negative control).
# Emits eval-able:  PL_ON=n PL_TOTAL=n PL_OFF=n PL_SEQS=n
pf_poc_lattice () {
  awk -F, -v maxlsb="${2:-0}" '
    function endseq(   i, half, dp, dt, h, lim, base, M, m, raw, prev, msb) {
      if (cnt == 0) return
      seqs++
      if (cnt == 1) { total++; on++; cnt = 0; return }
      # unwrap pic_order_cnt_lsb -> full POC (§8.2.1.1), msb 0 at the sequence
      # head; comparisons are between consecutive RAW lsb values
      M = maxlsb + 0
      if (M <= 0) { m = 0; for (i = 1; i <= cnt; i++) if (poc[i] > m) m = poc[i]; M = 16; while (M <= m) M *= 2 }
      msb = 0; prev = poc[1]
      for (i = 2; i <= cnt; i++) {
        raw = poc[i]
        if (raw < prev && prev - raw >= M / 2) msb += M
        else if (raw > prev && raw - prev > M / 2) msb -= M
        prev = raw; poc[i] = raw + msb
      }
      half = 0; lim = (cnt < 16 ? cnt : 16)
      for (i = 2; i <= lim && !half; i++) {
        dp = poc[i] - poc[1]; dt = pts[i] - pts[1]
        if (dp != 0) { h = dt / dp; if (h > 0 && h == int(h)) half = h }
      }
      if (half == 0) { total += cnt; off += cnt; cnt = 0; return }
      base = pts[1] - poc[1] * half
      for (i = 1; i <= cnt; i++) {
        total++
        if (pts[i] == base + poc[i] * half) on++; else off++
      }
      cnt = 0
    }
    NF >= 3 {
      if ($1 + 0 == 1) endseq()
      cnt++; poc[cnt] = $2 + 0; pts[cnt] = $3 + 0
    }
    END{
      endseq()
      printf "PL_ON=%d\nPL_TOTAL=%d\nPL_OFF=%d\nPL_SEQS=%d\n", on+0, total+0, off+0, seqs+0
    }' "${1:?pf_poc_lattice needs TABLE_FILE}"
}
