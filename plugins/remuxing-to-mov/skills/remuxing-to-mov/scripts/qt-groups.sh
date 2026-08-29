#!/usr/bin/env bash
# qt-groups.sh — alternate-group post-pass for a multi-audio QuickTime .mov
# (WO 5.3). OPT-IN, operator-invoked; never wired into mov.sh's default path.
#
# WHY: QuickTime builds its language menu from tkhd `alternate_group` — audio
# tracks sharing one nonzero group ID, exactly one of them enabled, are offered
# as selectable alternates (QTFF: track_header_atom/alternate_group.md). With
# the keep-every-track default (WO 3.3) a multi-language deliverable therefore
# NEEDS the grouping. ffmpeg's MOV muxer exposes no alternate-group option
# (confirmed against `-h muxer=mov`), and the bench moved mid-work-order:
#   - ffmpeg 9.0.1 movenc writes alternate_group=1 on EVERY audio tkhd itself
#     (measured 2026-08-14, .mov and .mp4 modes, single- and multi-audio), so
#     fresh builds on this bench need nothing — this script no-ops on them;
#   - outputs built by 8.x-era movenc, third-party muxers, or a group-scrubbing
#     tool (`MP4Box -group-clean` zeroes every tkhd group — measured) can carry
#     alternate_group=0 (present-but-disabled tracks with no declared group —
#     no menu). Those are what this post-pass retrofits.
#
# WHY a 2-byte binary edit and not a remux tool (measured 2026-08-14, GPAC
# 26.07, full log in references/alternate-group.md):
#   - `MP4Box -group-add refTrack=0:switchID=-1:trackID=…` DOES write a shared
#     nonzero group on the named tracks, essence-preserved, moov kept up front
#     — the dossier's unfinished incantation, finished. But it rewrites the
#     whole moov (box layout visibly changes), so "nothing ELSE changed" has to
#     be TRUSTED, and it needs per-file track-ID bookkeeping;
#   - the import-option form (`MP4Box -add self#N:group=G` — the dossier's
#     first attempt) is measurably WRONG-SCOPED: it broke the uniform audio
#     grouping ({1,1,1} -> {5,1,1}) instead of setting one group in place;
#   - a gpac filter session (`gpac -i in.mov -o out.mov`) DROPS disabled
#     tracks (4 -> 2 measured) unless `:alltk` is given.
# The surgical patch wins on proof strength, not necessity: walk the real box
# tree (no byte scanning), patch the 16-bit alternate_group in each audio
# tkhd, and the byte-diff bound below makes losslessness a checked fact —
# exactly 2 bytes per patched track differ, mdat never read or written.
#
# What it does (source untouched; output atomic .part -> mv; blessed ONLY
# after every proof):
#   1. parse: top-level boxes -> moov -> per-trak tkhd (version/flags/group)
#      + mdia/hdlr handler type. tkhd must be exactly 92 B (v0) / 104 B (v1)
#      — any other size is malformed and the file is refused untouched;
#   2. decide: <2 audio tracks, or all audio already sharing one nonzero group
#      (not claimed by a non-audio track) -> nothing to do, write NOTHING;
#   3. patch a full copy: alternate_group := TARGET on every audio tkhd
#      (TARGET=1 unless a non-audio trak claims 1, then max(groups)+1);
#   4. prove, in the .part, before blessing (the WO 5.3 proof contract —
#      the binary edit is acceptable ONLY with the proofs in the script):
#      (a) byte-diff bound: `cmp -l` source vs part — every differing byte
#          position falls inside the patched 2-byte fields, none elsewhere,
#          and each patched field reads back TARGET;
#      (b) video essence: `ffmpeg -map 0:v -c copy -f md5` identical;
#      (c) audio essence: per-stream `-f streamhash -hash md5` identical;
#      (d) independent parse: `MP4Box -info` exits clean AND reports
#          "Alternate Group ID" on exactly the audio-track count (an
#          independent reader sees the semantics, not just our bytes);
#      (e) verify.sh source-vs-output green. Its verdict is its printed TEXT
#          (">> OK"/">> REVIEW"/">> FAIL"; OK and REVIEW BOTH exit 0 — the
#          accepted legacy contract in verify.sh's header): the text is
#          mapped here, and a REVIEW propagates as this script's exit 10.
#
# Enabled flags are REPORTED, never touched: movenc already writes exactly one
# enabled audio track (TN3177's requirement — C66's probed structure), and
# flipping enable bits is a mapping decision this post-pass has no mandate
# for. An enabled-count anomaly downgrades the verdict to REVIEW.
# Language tags ride mdhd/elng and survive every -c copy (WO 3.5) — the menu
# NAMES come from there; this pass only declares the grouping.
#
# Usage: scripts/qt-groups.sh INPUT.mov OUTPUT.mov
# Exit: 0 = grouped + proven, or nothing to do (says so, writes nothing);
#       10 = REVIEW (output written; verify flagged it, or enabled-count != 1);
#       1 = FAIL (malformed box / a proof failed); 2 = usage/environment.
# Machine-readable (stable API — extend only):
#   QTG_SUMMARY date=<YYYY-MM-DD> macos=<ver> mp4box=<ver> audio=<n>
#               enabled=<n> group=<G> patched=<n> out=<path|none>
# The verdict self-dates (ground rule 6): grouping semantics are a property of
# the QuickTime/macOS that will read them, and the proof toolchain versions.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes

# NOTE no apostrophes in the :? messages (bash 3.2 swallows lines after a quote
# opener inside ${1:?...} — the trim-to-idr.sh lesson).
IN="${1:?usage: qt-groups.sh INPUT.mov OUTPUT.mov (alternate-group post-pass; source is never touched)}"
OUT="${2:?need OUTPUT.mov (written atomically; the input is never edited in place)}"
[ $# -le 2 ] || { echo "unknown opt: $3" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
command -v MP4Box >/dev/null 2>&1 \
  || { echo "MP4Box not found — the independent-parse proof needs it (doctor.sh lists it; brew install gpac)" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-mux.sh"    # rtm_sibling_guard: one writer for "beside, never onto" (T1.11)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)

OSV=$(sw_vers -productVersion 2>/dev/null || echo '?')
TODAY=$(date +%Y-%m-%d)
MPV=$(MP4Box -version 2>&1 | awk '/GPAC version/{print $NF; exit}')

echo "== qt-groups: $IN -> $OUT =="

# --- box-tree walk (headers only; dd+od reads, no full-file scan) ---------------
# Byte scanning for "tkhd" would false-positive inside mdat; walking the real
# tree cannot. Reads are 8–16 B each, a few dozen total, at any file size.
F="$IN"
hex_at () {  # hex_at OFFSET LEN -> lowercase hex, empty on short read
  dd if="$F" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}
scan_children () {  # scan_children ABS_START ABS_END -> lines "typehex off size"
  local off="$1" end="$2" h sz tp
  while [ "$off" -lt "$end" ]; do
    [ $((off + 8)) -le "$end" ] || break          # truncated header: stop cleanly
    h=$(hex_at "$off" 8)
    [ ${#h} -eq 16 ] || break
    sz=$((16#${h:0:8})); tp=${h:8:8}
    if [ "$sz" -eq 1 ]; then                       # 64-bit largesize
      h=$(hex_at $((off + 8)) 8); [ ${#h} -eq 16 ] || break
      sz=$((16#$h))
      [ "$sz" -ge 16 ] || { echo "MALFORMED $off"; return 0; }
    elif [ "$sz" -eq 0 ]; then                     # box extends to end
      sz=$((end - off))
    elif [ "$sz" -lt 8 ]; then
      echo "MALFORMED $off"; return 0
    fi
    printf '%s %s %s\n' "$tp" "$off" "$sz"
    off=$((off + sz))
  done
}
# fourcc hex: moov=6d6f6f76 trak=7472616b tkhd=746b6864 mdia=6d646961
#             hdlr=68646c72 soun=736f756e

FSIZE=$(stat -c %s "$IN" 2>/dev/null || stat -f %z "$IN" 2>/dev/null || echo 0)
[ "$FSIZE" -gt 16 ] || { echo "not a usable file (size $FSIZE B): $IN" >&2; exit 2; }

TOP=$(scan_children 0 "$FSIZE")
case "$TOP" in *MALFORMED*) echo "malformed box structure (top level) — refusing to touch: $IN" >&2; exit 1;; esac
MOOV=$(printf '%s\n' "$TOP" | awk '$1=="6d6f6f76"{print $2, $3; exit}')
if [ -z "$MOOV" ]; then
  echo "no moov box found — not a QuickTime/ISOBMFF file: $IN" >&2
  echo "   (this post-pass only applies to a finished .mov; build one first: mov.sh)" >&2
  exit 2
fi
MOOV_OFF=${MOOV%% *}; MOOV_SZ=${MOOV##* }

# --- per-trak: tkhd (version/flags/group/goff) + hdlr handler -------------------
NTRAK=0
TK_GOFF=(); TK_GRP=(); TK_FLAGS=(); TK_HANDLER=()
TRAKS=$(scan_children $((MOOV_OFF + 8)) $((MOOV_OFF + MOOV_SZ)))
case "$TRAKS" in *MALFORMED*) echo "malformed box structure (inside moov) — refusing to touch" >&2; exit 1;; esac
while read -r tp toff tsz; do
  [ "$tp" = "7472616b" ] || continue             # trak only
  kids=$(scan_children $((toff + 8)) $((toff + tsz)))
  case "$kids" in *MALFORMED*) echo "malformed box structure (inside trak @$toff) — refusing to touch" >&2; exit 1;; esac
  tk=$(printf '%s\n' "$kids" | awk '$1=="746b6864"{print $2, $3; exit}')
  md=$(printf '%s\n' "$kids" | awk '$1=="6d646961"{print $2, $3; exit}')
  [ -n "$tk" ] || { echo "trak @$toff has no tkhd — refusing to touch" >&2; exit 1; }
  tkoff=${tk%% *}; tksz=${tk##* }
  ver=$((16#$(hex_at $((tkoff + 8)) 1)))
  flags=$((16#$(hex_at $((tkoff + 9)) 3)))
  # tkhd is a leaf with a fixed layout per version: v0=92 B, v1=104 B. Any
  # other size means a layout this script has not proven offsets for -> refuse
  # untouched (the WO 5.3 offset-check requirement).
  case "$ver" in
    0) [ "$tksz" -eq 92 ]  || { echo "tkhd v0 @$tkoff is $tksz B (want 92) — refusing to touch" >&2; exit 1; }
       goff=$((tkoff + 42));;   # 8 hdr + 4 ver/flags + 4+4 times + 4 id + 4 rsvd + 4 dur + 8 rsvd + 2 layer
    1) [ "$tksz" -eq 104 ] || { echo "tkhd v1 @$tkoff is $tksz B (want 104) — refusing to touch" >&2; exit 1; }
       goff=$((tkoff + 54));;   # 8 hdr + 4 ver/flags + 8+8 times + 4 id + 4 rsvd + 8 dur + 8 rsvd + 2 layer
    *) echo "tkhd @$tkoff has unknown version $ver — refusing to touch" >&2; exit 1;;
  esac
  grp=$((16#$(hex_at "$goff" 2)))
  handler="????????"
  if [ -n "$md" ]; then
    mdoff=${md%% *}; mdsz=${md##* }
    mkids=$(scan_children $((mdoff + 8)) $((mdoff + mdsz)))
    hd=$(printf '%s\n' "$mkids" | awk '$1=="68646c72"{print $2; exit}')
    # handler_type sits at hdlr+16 in both layouts (QT: after component type
    # mhlr; ISO: after pre_defined 0)
    [ -n "$hd" ] && handler=$(hex_at $((hd + 16)) 4)
  fi
  TK_GOFF[$NTRAK]=$goff; TK_GRP[$NTRAK]=$grp; TK_FLAGS[$NTRAK]=$flags
  TK_HANDLER[$NTRAK]=$handler
  NTRAK=$((NTRAK + 1))
done <<EOF
$TRAKS
EOF
[ "$NTRAK" -gt 0 ] || { echo "moov contains no trak boxes — refusing to touch" >&2; exit 1; }

# --- inventory + decision -------------------------------------------------------
# Language report is informational (menu NAMES come from mdhd/elng): i-th audio
# trak <-> i-th ffprobe audio stream, movenc writes traks in stream order.
LANGS=$(ffp -v error -select_streams a -show_entries stream_tags=language -of default=nw=1:nk=1 "$IN" 2>/dev/null | tr '\n' ' ')
AUD_N=0; AUD_ENABLED=0; AUD_GRPS=""; MAXGRP=0; NONAUD_CLAIMS=""
i=0
while [ "$i" -lt "$NTRAK" ]; do
  if [ "${TK_HANDLER[$i]}" = "736f756e" ]; then
    AUD_N=$((AUD_N + 1))
    [ $((TK_FLAGS[i] & 1)) -eq 1 ] && AUD_ENABLED=$((AUD_ENABLED + 1))
    AUD_GRPS="$AUD_GRPS ${TK_GRP[$i]}"
  else
    [ "${TK_GRP[$i]}" -ne 0 ] && NONAUD_CLAIMS="$NONAUD_CLAIMS ${TK_GRP[$i]}"
  fi
  [ "${TK_GRP[$i]}" -gt "$MAXGRP" ] && MAXGRP=${TK_GRP[$i]}
  i=$((i + 1))
done
echo "   tracks: $NTRAK total, $AUD_N audio ($AUD_ENABLED enabled); audio groups:${AUD_GRPS:- none}; languages: ${LANGS:-untagged}"

summary () {  # summary GROUP PATCHED OUTPATH
  echo "QTG_SUMMARY date=$TODAY macos=$OSV mp4box=$MPV audio=$AUD_N enabled=$AUD_ENABLED group=$1 patched=$2 out=$3"
}

if [ "$AUD_N" -eq 0 ]; then
  echo "   no audio tracks — nothing to group; writing nothing."
  summary 0 0 none; exit 0
fi
if [ "$AUD_N" -eq 1 ]; then
  echo "   single audio track — no alternate menu to drive; writing nothing."
  echo "   (ffmpeg 9.x tags even a lone audio track group=1; QuickTime needs it only for alternates.)"
  summary "${AUD_GRPS# }" 0 none; exit 0
fi
# conformant already? all audio groups equal, nonzero, unclaimed by non-audio
FIRSTG=$(printf '%s' "${AUD_GRPS# }" | awk '{print $1}')
UNIFORM=1
for g in $AUD_GRPS; do [ "$g" = "$FIRSTG" ] || UNIFORM=0; done
CLAIMED=0
for g in $NONAUD_CLAIMS; do [ "$g" = "$FIRSTG" ] && CLAIMED=1; done
if [ "$UNIFORM" -eq 1 ] && [ "$FIRSTG" -ne 0 ] && [ "$CLAIMED" -eq 0 ]; then
  if [ "$AUD_ENABLED" -eq 1 ]; then
    echo "   already grouped: all $AUD_N audio tkhds share alternate_group=$FIRSTG, exactly one enabled."
    echo "   Nothing to do; writing nothing. (Verdict of $TODAY on macOS $OSV.)"
    summary "$FIRSTG" 0 none; exit 0
  fi
  echo ">> grouping is fine (all audio in group $FIRSTG) but $AUD_ENABLED tracks are enabled — QuickTime" >&2
  echo "   wants exactly ONE enabled per alternate group (TN3177). This pass does not flip enable" >&2
  echo "   bits (a mapping decision, not a grouping one): rebuild with mov.sh, which writes exactly" >&2
  echo "   one enabled audio track, or review the file by hand. Writing nothing." >&2
  summary "$FIRSTG" 0 none; exit 10
fi

# --- patch target ---------------------------------------------------------------
TARGET=1
for g in $NONAUD_CLAIMS; do [ "$g" -eq 1 ] && TARGET=$((MAXGRP + 1)); done
echo "   grouping needed: audio tkhds ->${AUD_GRPS} (want all = $TARGET, nonzero + shared)"

# rtm_part, not a private copy (Constitution IV.1). The hand-built name here
# was BOTH a second definition of the part-name fact AND a shape the sibling
# guard could not see: `x.part.mov` does not match the `.part-<pid>-<epoch>.`
# pattern, so a source with that name was outside T1.11 entirely.
PART="$(rtm_part "$OUT")"   # extension-keeping (D6) + unique per process (A2)
cp "$IN" "$PART"

PATCHED=0; ALLOWED=""
HI=$(printf '%02x' $((TARGET / 256))); LO=$(printf '%02x' $((TARGET % 256)))
i=0
while [ "$i" -lt "$NTRAK" ]; do
  if [ "${TK_HANDLER[$i]}" = "736f756e" ] && [ "${TK_GRP[$i]}" -ne "$TARGET" ]; then
    goff=${TK_GOFF[$i]}
    printf "\x$HI\x$LO" | dd of="$PART" bs=1 seek="$goff" conv=notrunc 2>/dev/null
    ALLOWED="$ALLOWED $goff $((goff + 1))"
    PATCHED=$((PATCHED + 1))
  fi
  i=$((i + 1))
done
[ "$PATCHED" -gt 0 ] || { rm -f "$PART"; echo "internal: patch set empty on a non-conformant file" >&2; exit 1; }
# read-back: each patched field must now hold TARGET in the part
F="$PART"
i=0
while [ "$i" -lt "$NTRAK" ]; do
  if [ "${TK_HANDLER[$i]}" = "736f756e" ]; then
    got=$((16#$(hex_at "${TK_GOFF[$i]}" 2)))
    [ "$got" -eq "$TARGET" ] || { echo ">> FAIL: read-back at ${TK_GOFF[$i]} is $got, want $TARGET. Evidence kept at $PART." >&2; exit 1; }
  fi
  i=$((i + 1))
done
echo "   patched $PATCHED audio tkhd(s): alternate_group := $TARGET (2 bytes each, read back OK)"

# --- proofs (all must pass before the .part is blessed) -------------------------
# (a) byte-diff bound: cmp -l positions are 1-BASED; every difference must be a
#     patched byte, and there must be at least one (we changed something).
set +e; DIFFS=$(cmp -l "$IN" "$PART" 2>&1); CMPRC=$?; set -e
if [ "$CMPRC" -ne 1 ]; then
  echo ">> FAIL: cmp rc=$CMPRC (want 1 = files differ in-bounds). Evidence kept at $PART." >&2; exit 1
fi
eval "$(printf '%s\n' "$DIFFS" | awk -v allowed="${ALLOWED# }" '
  BEGIN { m = split(allowed, A, " "); for (k = 1; k <= m; k++) ok[A[k]] = 1 }
  NF >= 3 { n++; if (!(($1 - 1) in ok)) bad++ }
  END { printf "cmp_n=%d cmp_bad=%d\n", n + 0, bad + 0 }')"
if [ "${cmp_bad:-1}" -ne 0 ] || [ "${cmp_n:-0}" -lt 1 ] || [ "${cmp_n:-0}" -gt $((PATCHED * 2)) ]; then
  echo ">> FAIL: byte-diff proof — $cmp_n differing bytes, $cmp_bad outside the patched" >&2
  echo "   alternate_group fields (allowed:${ALLOWED}). Evidence kept at $PART." >&2
  exit 1
fi
echo "   proof (a) byte-diff: $cmp_n byte(s) differ, all inside the $PATCHED patched field(s); mdat untouched"

# (b)+(c) essence hashes — the WO 5.3 mandated form, both sides read in full
HAS_VIDEO=0
i=0; while [ "$i" -lt "$NTRAK" ]; do [ "${TK_HANDLER[$i]}" = "76696465" ] && HAS_VIDEO=1; i=$((i + 1)); done
# D2 sibling (CHECKUP-2026-08-27 / WO-1.15.4): the essence decodes are
# CAPTURED — in statement position a mid-decode ffmpeg failure was a silent
# ERR exit 1 that ate the "Evidence kept at $PART" pointer, and an
# empty-vs-empty hash pair would have read as a proof verdict (the C3 shape).
# A tool failure is UNPROVEN: announced, not blessed, pointer intact.
if [ "$HAS_VIDEO" -eq 1 ]; then
  v_rc=0
  V_IN=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN"   -map 0:v -c copy -f md5 - 2>/dev/null) || v_rc=$?
  V_OUT=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$PART" -map 0:v -c copy -f md5 - 2>/dev/null) || v_rc=$?
  if [ "$v_rc" -ne 0 ] || [ -z "$V_IN" ] || [ -z "$V_OUT" ]; then
    echo ">> proof (b) COULD NOT RUN: ffmpeg failed mid-decode (rc=$v_rc; in=${V_IN:-empty} out=${V_OUT:-empty})." >&2
    echo "   UNPROVEN is not proven — NOT blessing. Evidence kept at $PART." >&2; exit 1
  fi
  [ "$V_IN" = "$V_OUT" ] \
    || { echo ">> FAIL: video MD5 proof ($V_IN vs $V_OUT). Evidence kept at $PART." >&2; exit 1; }
  echo "   proof (b) video essence: $V_IN (identical)"
else
  echo "   proof (b) skipped: no video track (audio-only container; byte-diff bound already covers it)"
fi
a_rc=0
A_IN=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN"   -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null) || a_rc=$?
A_OUT=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$PART" -map 0:a -c copy -f streamhash -hash md5 - 2>/dev/null) || a_rc=$?
if [ "$a_rc" -ne 0 ] || [ -z "$A_IN" ] || [ -z "$A_OUT" ]; then
  echo ">> proof (c) COULD NOT RUN: ffmpeg failed mid-decode (rc=$a_rc; in=${A_IN:-empty} out=${A_OUT:-empty})." >&2
  echo "   UNPROVEN is not proven — NOT blessing. Evidence kept at $PART." >&2; exit 1
fi
[ "$A_IN" = "$A_OUT" ] \
  || { echo ">> FAIL: per-stream audio MD5 proof. Evidence kept at $PART." >&2; exit 1; }
echo "   proof (c) audio essence: $AUD_N per-stream MD5s identical"

# (d) independent parse: MP4Box must exit clean AND see the semantics
set +e; MPINFO=$(MP4Box -noprog -info "$PART" 2>&1); MPRC=$?; set -e
if [ "$MPRC" -ne 0 ]; then
  echo ">> FAIL: MP4Box -info rc=$MPRC on the patched file. Evidence kept at $PART." >&2; exit 1
fi
# -x: exact-line match — a bare substring grep would let "Alternate Group ID 10"
# satisfy TARGET=1 (the -info line is exactly "Alternate Group ID N", measured)
SEEN=$(printf '%s\n' "$MPINFO" | grep -cx "Alternate Group ID $TARGET" || true)
if [ "$SEEN" -ne "$AUD_N" ]; then
  echo ">> FAIL: MP4Box sees 'Alternate Group ID $TARGET' on $SEEN track(s), want $AUD_N." >&2
  echo "   Evidence kept at $PART." >&2
  exit 1
fi
echo "   proof (d) independent parse: MP4Box clean, Alternate Group ID $TARGET on all $AUD_N audio tracks"

# (e) verify.sh — source vs patched output; its REVIEW is preserved, not eaten.
# CONTRACT (accepted legacy, see verify.sh's header): verify.sh prints its
# verdict as TEXT (">> OK" / ">> REVIEW" / ">> FAIL") and exits 0 for BOTH OK
# and REVIEW — the exit code alone cannot tell them apart. Map the text, the
# way mov.sh/auto.sh/resync.sh do; the first cut of this script switched on
# the exit code and reported a REVIEW build as "green" (1.11 fix round,
# 2026-08-14 — the misdocumented contract that bred the bug is now written in
# verify.sh's own header).
set +e; VOUT=$(bash "$SELF_DIR/verify.sh" "$IN" "$PART" 2>&1); VRC=$?; set -e
VERD=FAIL
case "$VOUT" in *">> OK"*) VERD=OK;; *">> REVIEW"*) VERD=REVIEW;; esac
[ "$VRC" -eq 0 ] || VERD=FAIL   # a hard rc (1 FAIL / 2 usage) outranks any text
case "$VERD" in
  OK)     echo "   proof (e) verify.sh: green";;
  REVIEW) echo "   proof (e) verify.sh: REVIEW — passed through below (exit 10), output still blessed:"
          printf '%s\n' "$VOUT" | grep '^>> REVIEW' | sed 's/^/      /';;
  *)      printf '%s\n' "$VOUT" | tail -8 | sed 's/^/   /'
          echo ">> FAIL: verify.sh rc=$VRC on the patched file. Evidence kept at $PART." >&2
          exit 1;;
esac

mv -f "$PART" "$OUT"
echo "wrote: $OUT"
if [ "$AUD_ENABLED" -ne 1 ]; then
  echo ">> REVIEW: $AUD_ENABLED audio tracks enabled (QuickTime wants exactly one per group," >&2
  echo "   TN3177). Grouping is fixed and proven; the enable bits are the operator's call." >&2
  echo "qt-groups: REVIEW on macOS $OSV ($TODAY) — grouped, but enabled-count $AUD_ENABLED needs a human."
  summary "$TARGET" "$PATCHED" "$OUT"; exit 10
fi
if [ "$VERD" = REVIEW ]; then
  echo "qt-groups: REVIEW on macOS $OSV ($TODAY) — grouped + proven, verify.sh wants a human look."
  summary "$TARGET" "$PATCHED" "$OUT"; exit 10
fi
echo "qt-groups: GROUPED on macOS $OSV ($TODAY) — $AUD_N audio tracks share alternate_group=$TARGET,"
echo "   exactly one enabled; essence byte-identical (proofs a–e above). QuickTime language menu ready."
summary "$TARGET" "$PATCHED" "$OUT"
exit 0
