#!/usr/bin/env bash
# make-fixtures.sh — deterministic synthetic fixture corpus for the v1.11 phases.
#
# WHY this exists: three post-mortems happened because a failure class had no
# fixture — the fixes that followed were untestable until a synthetic source
# existed. This script mints every class the later phases exercise, offline and
# on demand, into tests/fixtures/ (gitignored; media never ships in git).
#
#   multilang.ts     EN/ES/EN-5.1 AC-3 — audio-policy phases (language-aware
#                    selection; no silent drops — every DROP is a WARN)
#   mixed.ts         AAC-eng + AC-3-spa stereo pair — the per-track `auto`
#                    split (WO 3.2): one mux where copy AND PCM access are
#                    each the right answer for a different track
#   dupe_lang.ts     MP2-eng + AC-3-eng stereo pair — the SAME-key duplicate
#                    for layout+language curation (WO 3.5): codec rank must
#                    decide (AC-3 lossy-high beats MP2 lossy-low), not order
#   late-sps.ts      mid-GOP start, first SPS ~8 MB in — probe-layer phases
#                    (default probesize misses the dimensions a bigger one finds)
#   gap.ts           clean transport, one forward timeline gap — ts-health /
#                    diagnose routing (the "mux will succeed" desync class)
#   corrupt.ts       gap.ts plus genuine transport damage (TEI + PES-length
#                    rot) — damage-vs-timeline separation in the same scanners
#   rot.ts           mpegts/mpeg2video with a forward gap AND a backward DTS
#                    step (the backhaul timeline-rot class) — the WO 4.2
#                    demoted gate: warn + build + verify judges, never a
#                    pre-build exit 11
#   m2v422.mov/.ts,  the QT-undecodable 4:2:2 family plus 8/10-bit H.264 and
#   h264_422*.ts,    HEVC Rext (hvc1) — backhaul-gate phases; m2v420.ts is the
#   hevc_422_10.mov, verified-good 4:2:0 control that must keep passing
#   m2v420.ts
#   aac.ts           H.264 + ADTS AAC control — ffmpeg auto-inserts
#                    aac_adtstoasc on TS→MOV; pinned so nobody "fixes" it
#   mp4v/mjpeg/dv/   native-QuickTime matrix MOVs — coverage/messaging phases
#   prores .mov      (codec facts checked here; playability is a bench fact)
#   pcm_bluray.m2ts  Blu-ray LPCM in an .m2ts — the class entry 1 validated on
#                    an operator-held 18.5 GB real source, now mintable locally
#   vp9.webm         VP9 in WebM — the un-muxable-into-MOV class (WO 5.2):
#                    mov.sh must refuse with routes, never a raw muxer error
#
# Usage: bash make-fixtures.sh [FIXTURE...]
#   no args = build all. A FIXTURE arg is a filename (gap.ts) or stem (m2v422
#   matches m2v422.mov and m2v422.ts). Idempotent: regenerates in place.
# Exit: 0 = every requested fixture built AND self-checked; 1 = a fixture's
#   stated property does not hold (named on stderr); 2 = usage/env.
#
# House rules honored: outputs are atomic (.part -> mv; the plugin .gitignore
# already ignores *.part); nothing here touches any source media; bash 3.2 +
# POSIX awk only (od -t u1 feeds awk decimal bytes — never rely on "0x"+0 hex
# coercion, the remux.sh:69 class of trap); every recipe is offline and
# deterministic (fixed lavfi sources, fixed noise seed — encoder threading may
# flip bits run-to-run, but every stated property is invariant).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FIX="$SELF_DIR/fixtures"
TSH="$SELF_DIR/../scripts/ts-health.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch

command -v ffmpeg  >/dev/null 2>&1 || { echo "make-fixtures: ffmpeg not found"  >&2; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "make-fixtures: ffprobe not found" >&2; exit 2; }
mkdir -p "$FIX"

ALL="multilang.ts mixed.ts dupe_lang.ts late-sps.ts gap.ts corrupt.ts rot.ts m2v422.mov m2v422.ts h264_422.ts h264_422_10.ts hevc_422_10.mov m2v420.ts aac.ts mp4v.mov mjpeg.mov dv.mov prores.mov pcm_bluray.m2ts vp9.webm"

FFE () { ffmpeg -nostdin -y -v error "$@"; }
fail () { echo "FIXTURE FAILED: $1 — $2" >&2; exit 1; }
built () { # built NAME "property summary" — the one line per fixture
  printf 'OK   %-16s %10s B  %s\n' "$1" "$(wc -c < "$FIX/$1" | tr -d ' ')" "$2"
}
# single ffprobe value. mpegts probing lists every stream TWICE — a bare view
# first, then the in-program view, and only the program view carries the PMT
# tags (language!). The LAST non-empty line is therefore the authoritative one;
# single-listing containers (mov) are unaffected.
p1 () { # p1 FILE SELECT ENTRIES
  # trailing-comma sub: ffprobe 8 appends one on some csv rows (the ts-health
  # "test-18 lesson", visible on stream rows too)
  ffprobe -v error -select_streams "$2" -show_entries "$3" -of csv=p=0 "$1" 2>/dev/null |
    awk 'NF{last=$0} END{sub(/,+$/,"",last); print last}'
}
# one ts-health --kv run into $TMP/kv.txt (rc 10 = FINDINGS is expected on the
# damaged fixtures, hence || true), then field lookups from the file
tsh_scan () { bash "$TSH" "$1" --kv > "$TMP/kv.txt" 2>/dev/null || true; }
tsh_get () { awk -F= -v k="$1" '$1==k{print $2}' "$TMP/kv.txt"; }
# poke FILE OFFSET BYTE... — overwrite bytes in place (decimal), dd conv=notrunc
poke () {
  local f="$1" off="$2" b; shift 2
  for b in "$@"; do
    printf "\\$(printf '%03o' "$b")" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
    off=$((off+1))
  done
}
# ts_scan FILE — one line per 188-byte TS packet: "pkt pid pusi afc aflen",
# via od -t u1 (decimal bytes; POSIX) so awk never has to parse hex
ts_scan () {
  od -v -A n -t u1 "$1" | awk '
    { for(i=1;i<=NF;i++){ b=$i+0; p=n%188
        if(p==1){ b1=b } else if(p==2){ b2=b } else if(p==3){ b3=b }
        else if(p==4){ printf "%d %d %d %d %d\n", int(n/188),
          (b1%32)*256+b2, int(b1/64)%2, int(b3/16)%4, b }
        n++ } }'
}

# ---- shared base for gap.ts / corrupt.ts -----------------------------------
# WHY a setpts jump instead of the naive dd middle-carve: carving TS packets
# out breaks continuity counters (1/16 odds per PID of lining back up) and
# usually tears a PES packet, so the "clean transport, dirty timeline" class
# is unreachable that way. One encode with a +4 s PTS/DTS jump at t=10 gives
# a byte-clean stream whose only defect IS the forward gap — exactly the
# "present + monotonic, the mux will succeed" desync shape ts-health routes.
build_gap_base () { # build_gap_base OUT
  FFE -f lavfi -i "testsrc2=size=640x360:rate=25:duration=20" \
      -f lavfi -i "sine=frequency=440:duration=20:sample_rate=48000" \
      -filter_complex "[0:v]setpts=PTS+gte(N\,250)*(4/TB)[v];[1:a]asetpts=PTS+gte(T\,10)*(4/TB)[a]" \
      -map "[v]" -map "[a]" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
      -g 50 -sc_threshold 0 -c:a mp2 -b:a 192k -f mpegts "$1"
}

# ---- F1: EN stereo + ES stereo + EN 5.1, all AC-3, languages tagged --------
# WHY: the audio-policy phases need a source where "grab the first audio
# stream" is provably wrong — selection must be language- and layout-aware,
# and any dropped track must WARN (house rule 5).
fx_multilang () {
  local out="$FIX/multilang.ts.part" line
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
      -f lavfi -i "sine=frequency=660:duration=5:sample_rate=48000" \
      -f lavfi -i "sine=frequency=880:duration=5:sample_rate=48000" \
      -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -pix_fmt yuv420p -g 25 \
      -c:a:0 ac3 -ac:a:0 2 -metadata:s:a:0 language=eng \
      -c:a:1 ac3 -ac:a:1 2 -metadata:s:a:1 language=spa \
      -c:a:2 ac3 -ac:a:2 6 -metadata:s:a:2 language=eng -f mpegts "$out"
  # self-check: three AC-3 streams, channels 2/2/6, languages eng/spa/eng
  local want i
  i=0
  for want in "ac3,2,eng" "ac3,2,spa" "ac3,6,eng"; do
    line=$(p1 "$out" "a:$i" "stream=codec_name,channels:stream_tags=language")
    [ "$line" = "$want" ] || fail multilang.ts "audio stream $i is '$line', want '$want'"
    i=$((i+1))
  done
  mv "$out" "$FIX/multilang.ts"
  built multilang.ts "3x AC-3 eng/spa/eng 2/2/6ch, languages survive the TS mux"
}

# ---- F1b: AAC-eng + AC-3-spa stereo pair (WO 3.2) --------------------------
# WHY: the per-track `auto` fix needs a source where the RIGHT answer differs
# per kept track in the SAME mux — the AAC track must copy bit-exact (mp4a)
# while the AC-3 track lands as PCM access (TN2429: desktop QuickTime has no
# AC-3 decode). Pre-3.2, mov.sh's multi branch printed the PCM-access promise
# and then copied the AC-3 through. Both tracks are stereo ON PURPOSE: the
# regression drives the multi shape via --audio-keep all, and since WO 3.5
# the same-layout DIFFERENT-language pair also pins the `layouts` policy's
# distinct-deliverable branch (stereo/eng and stereo/spa both survive; the
# same-key rank curation lives in dupe_lang.ts below).
fx_mixed () {
  local out="$FIX/mixed.ts.part" line want i
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
      -f lavfi -i "sine=frequency=660:duration=5:sample_rate=48000" \
      -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -g 25 \
      -c:a:0 aac -b:a:0 128k -ac:a:0 2 -metadata:s:a:0 language=eng \
      -c:a:1 ac3 -b:a:1 192k -ac:a:1 2 -metadata:s:a:1 language=spa -f mpegts "$out"
  # self-check: aac then ac3, both stereo, languages eng/spa survive the TS mux
  i=0
  for want in "aac,2,eng" "ac3,2,spa"; do
    line=$(p1 "$out" "a:$i" "stream=codec_name,channels:stream_tags=language")
    [ "$line" = "$want" ] || fail mixed.ts "audio stream $i is '$line', want '$want'"
    i=$((i+1))
  done
  mv "$out" "$FIX/mixed.ts"
  built mixed.ts "AAC-eng + AC-3-spa stereo pair; the per-track auto split class"
}

# ---- F1c: MP2-eng + AC-3-eng stereo pair (WO 3.5) ---------------------------
# WHY: the layout+language curation needs a SAME-key duplicate pair (same
# layout, same language) where the winner is decided by codec rank alone.
# The MP2 (lossy-low) sits FIRST on purpose: the survivor must be a:1 AC-3
# (lossy-high), so a pass proves rank-based curation — a first-wins
# regression, or the pre-3.5 layout-only key colliding differently, keeps
# the wrong track and fails loudly. Every eviction stays a WARN (house
# rule 5); the drop rows are what 35-layouts-language.sh pins.
fx_dupe_lang () {
  local out="$FIX/dupe_lang.ts.part" line want i
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
      -f lavfi -i "sine=frequency=660:duration=5:sample_rate=48000" \
      -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -g 25 \
      -c:a:0 mp2 -b:a:0 192k -ac:a:0 2 -metadata:s:a:0 language=eng \
      -c:a:1 ac3 -b:a:1 192k -ac:a:1 2 -metadata:s:a:1 language=eng -f mpegts "$out"
  # self-check: mp2 THEN ac3 (order is the property), both stereo, both eng
  i=0
  for want in "mp2,2,eng" "ac3,2,eng"; do
    line=$(p1 "$out" "a:$i" "stream=codec_name,channels:stream_tags=language")
    [ "$line" = "$want" ] || fail dupe_lang.ts "audio stream $i is '$line', want '$want'"
    i=$((i+1))
  done
  mv "$out" "$FIX/dupe_lang.ts"
  built dupe_lang.ts "MP2-eng + AC-3-eng stereo pair; same-key duplicate, rank decides"
}

# ---- F2: mid-GOP start, first SPS ~8 MB in ---------------------------------
# WHY: real captures that join a broadcast mid-GOP carry their first SPS
# megabytes in; ffprobe's default 5 MB probe window reports a video stream
# with NO dimensions, and probe-layer code that trusts that first answer
# mis-routes the file. The window math is deliberate: the head slice lands
# 8 MiB before the surviving IDR — over the 5 MB default probesize (so the
# default probe fails) yet, at ~20 Mbit/s, ~3 s of stream time — inside the
# default 5 s analyzeduration (so -probesize 500M ALONE recovers dimensions,
# exactly the acceptance property).
fx_late_sps () {
  local full="$TMP/late-full.ts" out="$FIX/late-sps.ts.part"
  # ~20 Mbit/s so GOPs are wide in bytes: temporal+uniform noise (fixed seed —
  # determinism) defeats testsrc2's compressibility; -g 250 @25fps = 10 s GOP;
  # -sc_threshold 0 stops scene-cut IDRs from shrinking the window
  FFE -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=25,noise=all_seed=4242:alls=48:allf=t+u" \
      -f lavfi -i "sine=frequency=440:duration=25:sample_rate=48000" \
      -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
      -b:v 20M -g 250 -sc_threshold 0 -c:a mp2 -b:a 192k -f mpegts "$full"
  # find the first two IDR byte positions, then cut 8 MiB ahead of IDR#2.
  # awk never early-exits on these big packet lists: under pipefail an early
  # exit SIGPIPEs ffprobe and fails the pipeline — consume to EOF instead
  local kf1 kf2 target cut
  ffprobe -v error -select_streams v:0 -show_entries packet=pos,flags -of csv=p=0 "$full" 2>/dev/null |
    awk -F, 'index($2,"K") && k<2 {print $1+0; k++}' > "$TMP/kf.txt"
  kf1=$(awk 'NR==1' "$TMP/kf.txt"); kf2=$(awk 'NR==2' "$TMP/kf.txt")
  [ -n "${kf2:-}" ] || fail late-sps.ts "fewer than two IDRs in the full encode"
  [ $((kf2 - kf1)) -gt 12000000 ] || fail late-sps.ts "GOP only $((kf2-kf1)) B — encoder undershot the 20 Mbit/s target; widen noise strength"
  target=$((kf2 - 8388608))
  [ "$target" -gt $((kf1 + 2097152)) ] || fail late-sps.ts "cut target would land inside IDR#1's data"
  cut=$(ffprobe -v error -select_streams v:0 -show_entries packet=pos -of csv=p=0 "$full" 2>/dev/null |
        awk -F, -v t="$target" '!done && $1+0>=t {print $1+0; done=1}')
  [ -n "$cut" ] || fail late-sps.ts "no video packet at/after byte $target"
  # ffmpeg's TS muxer 188-aligns PES starts; keep the dd slice valid regardless
  [ $((cut % 188)) -eq 0 ] || cut=$(( (cut / 188) * 188 ))
  dd if="$full" of="$out" bs=188 skip=$((cut / 188)) status=none
  # self-check: THE property — default probe has no dimensions, bigger probe does
  local wd wb hb
  wd=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$out" 2>/dev/null | head -1)
  case "${wd:-}" in ''|0|N/A) : ;; *) fail late-sps.ts "default probe already sees width=$wd (SPS not late enough)";; esac
  wb=$(ffprobe -v error -probesize 500M -select_streams v:0 -show_entries stream=width  -of default=nw=1:nk=1 "$out" 2>/dev/null | head -1)
  hb=$(ffprobe -v error -probesize 500M -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$out" 2>/dev/null | head -1)
  { [ "$wb" = 1280 ] && [ "$hb" = 720 ]; } || fail late-sps.ts "-probesize 500M sees ${wb}x${hb}, want 1280x720"
  mv "$out" "$FIX/late-sps.ts"
  built late-sps.ts "mid-GOP head: default probe blind, -probesize 500M sees 1280x720"
}

# ---- F3: clean transport, one forward timeline gap -------------------------
fx_gap () {
  local out="$FIX/gap.ts.part" gaps cc crp pes
  build_gap_base "$out"
  # self-check: >=1 forward gap and ZERO transport-level errors — the whole
  # point of this fixture is that only the timeline is dirty
  tsh_scan "$out"
  gaps=$(tsh_get TSH_GAPS); cc=$(tsh_get TSH_CC)
  crp=$(tsh_get TSH_CORRUPT); pes=$(tsh_get TSH_PES)
  [ "${gaps:-0}" -ge 1 ] || fail gap.ts "ts-health saw no forward gap (TSH_GAPS=$gaps)"
  { [ "${cc:-1}" -eq 0 ] && [ "${crp:-1}" -eq 0 ] && [ "${pes:-1}" -eq 0 ]; } ||
    fail gap.ts "transport not clean (CC=$cc corrupt=$crp PES=$pes)"
  mv "$out" "$FIX/gap.ts"
  built gap.ts "1 forward gap (~4 s), transport clean (CC/TEI/PES all 0)"
}

# ---- F4: gap.ts plus genuine transport damage ------------------------------
# WHY: the scanners must keep "timeline dirt" (routable, lossless fixes exist)
# and "transport damage" (permanent, decoders conceal) apart. Damage is minted
# surgically so the file stays demuxable end-to-end: the TEI bit (byte1|0x80)
# on six mid-file video payload packets makes the demuxer flag/drop exactly
# those ("Packet corrupt"), and clobbering one audio PES length field trips
# "PES packet size mismatch" — video PES can't (ffmpeg writes video PES with
# length 0 = unbounded), which is why the audio stream takes that hit.
fx_corrupt () {
  local out="$FIX/corrupt.ts.part" n
  build_gap_base "$out"
  ts_scan "$out" > "$TMP/pkts.txt"
  n=$(wc -l < "$TMP/pkts.txt" | tr -d ' ')
  # stream PIDs from ffprobe (stream "id" IS the PID, hex) — never hard-code
  # the muxer's 0x100/0x101 defaults
  local vhex ahex vpid apid
  vhex=$(p1 "$out" v:0 stream=id); vhex=${vhex#0x}
  ahex=$(p1 "$out" a:0 stream=id); ahex=${ahex#0x}
  { [ -n "$vhex" ] && [ -n "$ahex" ]; } || fail corrupt.ts "could not read stream PIDs"
  vpid=$((16#$vhex)); apid=$((16#$ahex))
  # six evenly spaced video payload packets in the 40–60% band -> set TEI
  awk -v v="$vpid" -v lo=$((n*2/5)) -v hi=$((n*3/5)) \
      '$2==v && $3==0 && $1>=lo && $1<=hi' "$TMP/pkts.txt" > "$TMP/vcand.txt"
  local vc step pkt b1
  vc=$(wc -l < "$TMP/vcand.txt" | tr -d ' ')
  [ "$vc" -ge 6 ] || fail corrupt.ts "only $vc mid-file video packets to damage"
  step=$((vc / 6))
  # (NR-1)%s==0 keeps step=1 valid; ++c<=6 caps inside awk (no head in the
  # pipeline — pipefail + SIGPIPE hygiene)
  awk -v s="$step" '(NR-1)%s==0 && ++c<=6' "$TMP/vcand.txt" > "$TMP/vict.txt"
  while read -r pkt _rest; do
    b1=$(od -A n -t u1 -j $((pkt*188+1)) -N 1 "$out" | tr -d ' ')
    poke "$out" $((pkt*188+1)) $((b1 | 128))
  done < "$TMP/vict.txt"
  # one audio PES start past 50% -> corrupt its PES packet length to 8 bytes.
  # Verify the payload really starts 00 00 01 C0 (MP2 stream id) before poking;
  # afc 3 means an adaptation field precedes the payload (aflen byte at +4).
  local done_a=0 apkt aafc aaflen poff magic
  while read -r apkt _pid _pusi aafc aaflen; do
    if [ "$aafc" -eq 3 ]; then poff=$((apkt*188 + 5 + aaflen)); else poff=$((apkt*188 + 4)); fi
    # NR==1: macOS od appends a bare trailing line even with -A n
    magic=$(od -A n -t u1 -j "$poff" -N 4 "$out" | awk 'NR==1{print $1","$2","$3","$4}')
    if [ "$magic" = "0,0,1,192" ]; then
      poke "$out" $((poff + 4)) 0 8
      done_a=1; break
    fi
  done < <(awk -v a="$apid" -v mid=$((n/2)) '$2==a && $3==1 && $1>=mid' "$TMP/pkts.txt")
  [ "$done_a" -eq 1 ] || fail corrupt.ts "no clean audio PES start found to damage"
  # self-check: both damage counters nonzero, gap inherited from the base
  local crp pes gaps
  tsh_scan "$out"
  crp=$(tsh_get TSH_CORRUPT); pes=$(tsh_get TSH_PES); gaps=$(tsh_get TSH_GAPS)
  [ "${crp:-0}" -ge 1 ] || fail corrupt.ts "TEI damage not detected (TSH_CORRUPT=$crp)"
  [ "${pes:-0}" -ge 1 ] || fail corrupt.ts "PES damage not detected (TSH_PES=$pes)"
  [ "${gaps:-0}" -ge 1 ] || fail corrupt.ts "lost the inherited forward gap (TSH_GAPS=$gaps)"
  mv "$out" "$FIX/corrupt.ts"
  built corrupt.ts "corrupt=$crp PES=$pes transport damage + the inherited gap"
}

# ---- F4c: backhaul timeline rot (forward gap + backward DTS) ----------------
# WHY: the WO 4.2 demotion (rot refusal -> warn + build + verify judges) needs
# the actual refused class as a real file, not just injected DTS lists: mpegts
# + mpeg2video + at least one forward gap + at least one non-monotonic (backward
# /duplicate) DTS. A single encode cannot mint backward DTS (the TS muxer
# refuses to write it), so the rot is spliced: three COMPLETE, individually
# clean TS segments cat'd with clashing -output_ts_offset values — segment 2
# jumps the clock +20 s (forward gap at splice 1), segment 3 rewinds it to +8 s
# (backward DTS step at splice 2). Every defect is a splice-point timeline
# jump; the handful of demuxer "Packet corrupt" flags at the splices is small
# by construction (far under the TSH_LOSS_FAIL=100 damage threshold) — exactly
# the real splice-rot shape (the 2009/2012 feeds were spliced captures too).
# MP2 audio rides along on purpose: the backhaul class carries MP2, and the
# audio is what verify's dual-track/parity gates measure on the built .mov.
fx_rot () {
  local out="$FIX/rot.ts.part" off gaps back dup verdict line
  : > "$out"
  for off in 0 20 8; do
    FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=2" \
        -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
        -map 0:v -map 1:a -c:v mpeg2video -b:v 2M -pix_fmt yuv420p \
        -c:a mp2 -b:a 192k -output_ts_offset "$off" -f mpegts "$TMP/rotseg.ts"
    cat "$TMP/rotseg.ts" >> "$out"
  done
  # self-check: the stated class must hold — BOTH rot ingredients present,
  # transport dirt small enough that ts-health still says FINDINGS, not DAMAGED
  line=$(p1 "$out" v:0 stream=codec_name),$(p1 "$out" a:0 stream=codec_name)
  [ "$line" = "mpeg2video,mp2" ] || fail rot.ts "streams are '$line', want 'mpeg2video,mp2'"
  tsh_scan "$out"
  gaps=$(tsh_get TSH_GAPS); back=$(tsh_get TSH_BACK); dup=$(tsh_get TSH_DUP)
  verdict=$(tsh_get TSH_VERDICT)
  [ "${gaps:-0}" -ge 1 ] || fail rot.ts "no forward gap detected (TSH_GAPS=$gaps)"
  [ $(( ${back:-0} + ${dup:-0} )) -ge 1 ] || fail rot.ts "no DTS rot detected (back=$back dup=$dup)"
  [ "${verdict:-}" = FINDINGS ] || fail rot.ts "verdict '$verdict', want FINDINGS (splice dirt must stay under the damage threshold)"
  mv "$out" "$FIX/rot.ts"
  built rot.ts "gaps=$gaps back=$back dup=$dup — the demoted (WO 4.2) rot class"
}

# ---- F5/F6: the 4:2:2 family + the 4:2:0 control ---------------------------
# WHY: QuickTime cannot decode MPEG-2 4:2:2 (distorts) or H.264 High 4:2:2
# (stalls) however healthy the file — the refused backhaul class. The TS
# variants carry MP2 like the real 2017-feed captures; m2v420.ts is the
# verified-good control that must KEEP passing the gates.
build_v () { # build_v OUT NAME CODEC PIXFMT EXTRA... (video-only MOV; -f mov
             # is explicit because the .part suffix hides the extension)
  local out="$1" name="$2" codec="$3" pix="$4"; shift 4
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -c:v "$codec" -pix_fmt "$pix" "$@" -f mov "$out"
  check_v "$out" "$name" "$codec" "$pix"
}
build_vts () { # build_vts OUT NAME CODEC PIXFMT EXTRA... (mpegts + MP2 audio)
  local out="$1" name="$2" codec="$3" pix="$4"; shift 4
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
      -map 0:v -map 1:a -c:v "$codec" -pix_fmt "$pix" "$@" \
      -c:a mp2 -b:a 192k -f mpegts "$out"
  check_v "$out" "$name" "$codec" "$pix"
}
check_v () { # check_v FILE NAME CODEC PIXFMT — the codec facts ARE the property
  local got want="$3,$4"
  got=$(p1 "$1" v:0 stream=codec_name,pix_fmt)
  # libx264/x265 report their wrapper names back as h264/hevc
  case "$3" in libx264) want="h264,$4";; libx265) want="hevc,$4";; esac
  [ "$got" = "$want" ] || fail "$2" "video is '$got', want '$want'"
}

fx_m2v422_mov () {
  build_v "$FIX/m2v422.mov.part" m2v422.mov mpeg2video yuv422p -b:v 5M
  mv "$FIX/m2v422.mov.part" "$FIX/m2v422.mov"
  built m2v422.mov "mpeg2video yuv422p in MOV (QT-undecodable pixel format)"
}
fx_m2v422_ts () {
  build_vts "$FIX/m2v422.ts.part" m2v422.ts mpeg2video yuv422p -b:v 5M
  mv "$FIX/m2v422.ts.part" "$FIX/m2v422.ts"
  built m2v422.ts "mpeg2video yuv422p + MP2 in TS (refused backhaul shape)"
}
fx_h264_422 () {
  build_vts "$FIX/h264_422.ts.part" h264_422.ts libx264 yuv422p -preset veryfast
  mv "$FIX/h264_422.ts.part" "$FIX/h264_422.ts"
  built h264_422.ts "H.264 High 4:2:2 8-bit + MP2 in TS (the 2017-feed class)"
}
fx_h264_422_10 () {
  build_vts "$FIX/h264_422_10.ts.part" h264_422_10.ts libx264 yuv422p10le -preset veryfast
  mv "$FIX/h264_422_10.ts.part" "$FIX/h264_422_10.ts"
  built h264_422_10.ts "H.264 High 4:2:2 10-bit + MP2 in TS"
}
fx_hevc_422_10 () {
  local out="$FIX/hevc_422_10.mov.part" tag
  build_v "$out" hevc_422_10.mov libx265 yuv422p10le -preset fast -tag:v hvc1
  tag=$(p1 "$out" v:0 stream=codec_tag_string)
  [ "$tag" = hvc1 ] || fail hevc_422_10.mov "codec tag is '$tag', want hvc1"
  mv "$out" "$FIX/hevc_422_10.mov"
  built hevc_422_10.mov "HEVC Rext yuv422p10le tagged hvc1 in MOV"
}
fx_m2v420 () {
  local out="$FIX/m2v420.ts.part" a
  build_vts "$out" m2v420.ts mpeg2video yuv420p -b:v 5M
  a=$(p1 "$out" a:0 stream=codec_name)
  [ "$a" = mp2 ] || fail m2v420.ts "audio is '$a', want mp2"
  mv "$out" "$FIX/m2v420.ts"
  built m2v420.ts "mpeg2video yuv420p + MP2 (verified-good control: must pass)"
}

# ---- F7: H.264 + ADTS AAC control ------------------------------------------
fx_aac () {
  local out="$FIX/aac.ts.part" got
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
      -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
      -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
      -c:a aac -b:a 128k -f mpegts "$out"
  got="$(p1 "$out" v:0 stream=codec_name),$(p1 "$out" a:0 stream=codec_name)"
  [ "$got" = "h264,aac" ] || fail aac.ts "streams are '$got', want 'h264,aac'"
  mv "$out" "$FIX/aac.ts"
  built aac.ts "H.264 + ADTS AAC (control: aac_adtstoasc auto-insert must keep working)"
}

# ---- F8: native-QuickTime matrix MOVs --------------------------------------
# dvvideo demands legal DV geometry: PAL 720x576@25 is 4:2:0 — generate at
# that size directly rather than scaling. mjpeg stays yuvj420p (the known-
# playable family; MJPEG 4:2:2 is a separate open question on the bench).
fx_mp4v () {
  local out="$FIX/mp4v.mov.part" tag
  build_v "$out" mp4v.mov mpeg4 yuv420p -q:v 4
  tag=$(p1 "$out" v:0 stream=codec_tag_string)
  [ "$tag" = mp4v ] || fail mp4v.mov "codec tag is '$tag', want mp4v"
  mv "$out" "$FIX/mp4v.mov"
  built mp4v.mov "MPEG-4 Part 2 tagged mp4v in MOV (native matrix)"
}
fx_mjpeg () {
  build_v "$FIX/mjpeg.mov.part" mjpeg.mov mjpeg yuvj420p -q:v 4
  mv "$FIX/mjpeg.mov.part" "$FIX/mjpeg.mov"
  built mjpeg.mov "Motion JPEG 4:2:0 in MOV (native matrix)"
}
fx_dv () {
  local out="$FIX/dv.mov.part" got
  FFE -f lavfi -i "testsrc2=size=720x576:rate=25:duration=5" \
      -c:v dvvideo -pix_fmt yuv420p -f mov "$out"
  got=$(p1 "$out" v:0 stream=codec_name,width,height)
  [ "$got" = "dvvideo,720,576" ] || fail dv.mov "video is '$got', want dvvideo,720,576"
  mv "$out" "$FIX/dv.mov"
  built dv.mov "DV PAL 720x576@25 in MOV (native matrix)"
}
fx_prores () {
  build_v "$FIX/prores.mov.part" prores.mov prores yuv422p10le
  mv "$FIX/prores.mov.part" "$FIX/prores.mov"
  built prores.mov "ProRes 422 (apcn) in MOV (native matrix)"
}

# ---- F4b: Blu-ray LPCM in .m2ts --------------------------------------------
# WHY: entry-1 validation ran against an operator-held 18.5 GB real disc rip;
# this bench's ffmpeg HAS the pcm_bluray encoder, so the class is mintable at
# fixture size. m2ts mode is required — LPCM's 0x80 stream type only exists in
# the BDAV mapping. If the mux ever fails on a leaner ffmpeg build, SKIP (with
# the provenance note) rather than fail the whole corpus: the later phases
# treat this fixture as best-effort.
fx_pcm_bluray () {
  local out="$FIX/pcm_bluray.m2ts.part" a
  if ! FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=5" \
       -f lavfi -i "sine=frequency=440:duration=5:sample_rate=48000" \
       -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
       -c:a pcm_bluray -ar 48000 -ac 2 -mpegts_m2ts_mode 1 -f mpegts "$out" 2>"$TMP/pcmblu.err"; then
    rm -f "$out"
    echo "SKIP pcm_bluray.m2ts — mux failed on this ffmpeg ($(head -1 "$TMP/pcmblu.err" 2>/dev/null)); entry-1 validation used the operator-held 18.5 GB real source"
    return 0
  fi
  a=$(p1 "$out" a:0 stream=codec_name)
  [ "$a" = pcm_bluray ] || fail pcm_bluray.m2ts "audio is '$a', want pcm_bluray"
  mv "$out" "$FIX/pcm_bluray.m2ts"
  built pcm_bluray.m2ts "H.264 + Blu-ray LPCM in BDAV .m2ts (m2ts mode)"
}

# ---- F9: VP9 in WebM (WO 5.2) -----------------------------------------------
# WHY: the unroutable-codec gate needs its verified class as a real file — the
# MOV muxer rejects VP9 outright ("vp9 only supported in MP4", bench-verified
# ffmpeg 9.0.1 2026-08-14), and pre-1.11 that surfaced as a raw header-write
# failure mid-build instead of a routed refusal. Video-only, tiny, fixed lavfi
# source. The self-check proves BOTH stated properties: the stream is VP9, and
# it still cannot be -c copy muxed into MOV on this ffmpeg — if a future ffmpeg
# learns VP9-in-MOV, this fails loudly and the WO 5.2 gate deserves a re-bench.
fx_vp9 () {
  local out="$FIX/vp9.webm.part" got
  FFE -f lavfi -i "testsrc2=size=320x240:rate=25:duration=2" \
      -c:v libvpx-vp9 -b:v 200k -pix_fmt yuv420p -f webm "$out"
  got=$(p1 "$out" v:0 stream=codec_name)
  [ "$got" = vp9 ] || fail vp9.webm "video is '$got', want vp9"
  if FFE -i "$out" -c copy -f mov "$TMP/vp9try.mov" 2>/dev/null; then
    fail vp9.webm "this ffmpeg MUXED vp9 into MOV — the unroutable premise no longer holds; re-bench the WO 5.2 gate"
  fi
  mv "$out" "$FIX/vp9.webm"
  built vp9.webm "VP9 in WebM; MOV mux verified impossible (the WO 5.2 refusal class)"
}

# ---- dispatch ---------------------------------------------------------------
run_one () {
  case "$1" in
    multilang.ts)    fx_multilang ;;
    mixed.ts)        fx_mixed ;;
    dupe_lang.ts)    fx_dupe_lang ;;
    late-sps.ts)     fx_late_sps ;;
    gap.ts)          fx_gap ;;
    corrupt.ts)      fx_corrupt ;;
    rot.ts)          fx_rot ;;
    m2v422.mov)      fx_m2v422_mov ;;
    m2v422.ts)       fx_m2v422_ts ;;
    h264_422.ts)     fx_h264_422 ;;
    h264_422_10.ts)  fx_h264_422_10 ;;
    hevc_422_10.mov) fx_hevc_422_10 ;;
    m2v420.ts)       fx_m2v420 ;;
    aac.ts)          fx_aac ;;
    mp4v.mov)        fx_mp4v ;;
    mjpeg.mov)       fx_mjpeg ;;
    dv.mov)          fx_dv ;;
    prores.mov)      fx_prores ;;
    pcm_bluray.m2ts) fx_pcm_bluray ;;
    vp9.webm)        fx_vp9 ;;
    *) echo "make-fixtures: internal dispatch error: $1" >&2; exit 2 ;;
  esac
}

if [ $# -eq 0 ]; then
  TODO="$ALL"
else
  TODO=""
  for arg in "$@"; do
    hit=""
    for f in $ALL; do
      case "$f" in "$arg"|"$arg".*) hit="$hit $f";; esac
    done
    if [ -z "$hit" ]; then
      echo "make-fixtures: unknown fixture '$arg'" >&2
      echo "known: $ALL" >&2
      exit 2
    fi
    TODO="$TODO$hit"
  done
fi

for f in $TODO; do run_one "$f"; done
echo "all requested fixtures built and self-checked -> $FIX"
