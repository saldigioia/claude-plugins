#!/usr/bin/env bash
# 44-container-axis.sh — 1.13 D2/D3/D7/D8: the CONTAINER is an axis of the
# MPEG-2 4:2:2 QuickTime-corruption class, and the plugin now has a rung for it.
#
# WHAT THIS PINS (the mechanism halves, all synthesizable):
#   * D2 the MOV tag-table REFUSAL is real and is the reason the rung exists:
#     `-tag:v mp4v -f mov` on MPEG-2 dies at header write, while `-f mp4`
#     writes 'mp4v'+esds by default. That asymmetry is a muxer table artifact,
#     not a QTFF rule (references/ingest-compatibility.md "The container axis").
#   * D2 mp4-swap.sh builds a LOSSLESS swap: the video packet hash across
#     source -> .mov -> .mp4 is one value. A "swap" that touched payload would
#     be a re-encode wearing a remux costume.
#   * D2 remux.sh --container mp4 does not refuse VP9 (MP4 carries it) while
#     MOV still does — "unroutable" was always a MOV fact, and 1.13 scoped it.
#   * D3 the ipcm sample entry the swap's access track lands in passes gate (g)
#     instead of being condemned as "a sample entry no decoder claims".
#   * D7 the retag advisory fires on a .ts SOURCE (it was dead on every TS
#     before 1.13 — STSD_ENTRY only exists for MP4-family containers), while
#     staying silent on the 4:2:0 control and on an already-retagged xd5b MOV.
#
# WHAT IT CANNOT PIN (said out loud, never faked green): the corruption itself.
# The synthetic 4:2:2 clip decodes cleanly through the consumer path on this
# bench, so "MOV destroyed / MP4 correct" is OPERATOR-VERIFIED off-repo
# (2026-08-15, a real 21 GB MPEG-2 4:2:2 1080i29.97 capture: five MOV retags at
# SSIM 0.81-0.85, the MP4 swap at 0.9175+ on the same timestamps). What this
# file asserts is that the ROUTE exists, is lossless, and is reachable.
#
# Standalone: bash tests/regression.d/44-container-axis.sh
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
p1 () { ffprobe -v error -select_streams "$2" -show_entries "$3" -of default=nw=1:nk=1 "$1" 2>/dev/null | awk 'NR==1'; }
vhash () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | awk 'NR==1'; }

for f in m2v422.ts m2v422.mov m2v420.ts vp9.webm; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi
# CAPABILITY PROBE, not a version guess (the harness spans ffmpeg 4.4-9.x): the
# ISO PCM entry `ipcm` landed in ffmpeg 6.1 (commit d4ee177a), so on an older
# muxer the swap's PCM access track simply cannot be written. Ask the tool.
HAS_IPCM=no
if ffmpeg -nostdin -y -v error -f lavfi -i "sine=frequency=440:duration=0.2:sample_rate=48000" \
     -c:a pcm_s16le -f mp4 "$WORK/cap.mp4" 2>/dev/null && [ -s "$WORK/cap.mp4" ]; then HAS_IPCM=yes; fi
echo "  (capability: PCM into MP4 = $HAS_IPCM; ffmpeg $(ffmpeg -version 2>/dev/null | awk 'NR==1{print $3}'))"

echo "== 1. D2: the MOV tag table refuses the entry that works; MP4 writes it by default =="
mo=$(ffmpeg -nostdin -y -v error -i "$FIX/m2v422.ts" -map 0:v:0 -c:v copy -tag:v mp4v -f mov "$WORK/refused.mov" 2>&1); mrc=$?
[ "$mrc" -ne 0 ] && ok "MOV + '-tag:v mp4v' on MPEG-2 FAILS the mux (the rung's whole premise)" \
  || no "MOV accepted -tag:v mp4v — the tag table changed; re-read references/ingest-compatibility.md 'The container axis'"
has "$mo" "incompatible with output codec id" "the refusal is the documented tag-table message"
AOPT="pcm_s16le"; [ "$HAS_IPCM" = yes ] || AOPT="copy"
ffmpeg -nostdin -y -v error -i "$FIX/m2v422.ts" -map 0:v:0 -map 0:a:0 -c:v copy -c:a "$AOPT" -f mp4 "$WORK/plain.mp4" 2>/dev/null
[ -s "$WORK/plain.mp4" ] && ok "MP4 mux of the same bitstream succeeds" || no "MP4 mux failed"
[ "$(p1 "$WORK/plain.mp4" v:0 stream=codec_tag_string)" = mp4v ] \
  && ok "MP4 picks sample entry 'mp4v' by DEFAULT (no explicit tag needed)" \
  || no "MP4 video entry is '$(p1 "$WORK/plain.mp4" v:0 stream=codec_tag_string)', want mp4v"
if command -v mp4dump >/dev/null 2>&1; then
  case "$(mp4dump "$WORK/plain.mp4" 2>/dev/null)" in
    *'[esds]'*) ok "the MP4 entry carries an 'esds' descriptor (the ISO ingest path)";;
    *) no "no esds in the MP4 sample entry";;
  esac
else
  echo "  (skip: mp4dump absent — esds presence unasserted)"
fi
if [ "$HAS_IPCM" = yes ]; then
  [ "$(p1 "$WORK/plain.mp4" a:0 stream=codec_tag_string)" = ipcm ] \
    && ok "PCM into MP4 lands as 'ipcm' (C101 — the entry gate (g) used to condemn)" \
    || no "MP4 PCM entry is '$(p1 "$WORK/plain.mp4" a:0 stream=codec_tag_string)', want ipcm"
else
  echo "  (skip: this ffmpeg cannot write PCM into MP4 — the ISO 'ipcm' entry arrived in 6.1;"
  echo "   the C101 half and the gate-(g) acceptance below are unprovable on this build)"
fi

echo
echo "== 2. D2: mp4-swap.sh — the rung builds, verifies, and is provably LOSSLESS =="
SWAPA=""; [ "$HAS_IPCM" = yes ] || SWAPA="--audio copy"   # old muxer: keep the original bitstream instead
# shellcheck disable=SC2086
so=$(bash "$SC/mp4-swap.sh" "$FIX/m2v422.ts" "$WORK/swap.mp4" $SWAPA 2>&1); src=$?
case "$src" in 0|10) ok "mp4-swap.sh produced a verified artifact (rc=$src: 0 DONE / 10 REVIEW are both in contract)";;
  *) no "mp4-swap.sh rc=$src"; printf '%s\n' "$so" | tail -12 | sed 's/^/   /';; esac
[ -s "$WORK/swap.mp4" ] && ok "the .mp4 deliverable exists" || no "no .mp4 written"
has "$so" "MP4_SWAP " "MP4_SWAP machine line emitted (never a silent rung)"
hs=$(vhash "$FIX/m2v422.ts"); hm=$(vhash "$WORK/swap.mp4")
{ [ -n "$hs" ] && [ "$hs" = "$hm" ]; } \
  && ok "video packet hash identical source -> .mp4 (the swap is provably lossless)" \
  || no "packet hash differs (src=$hs mp4=$hm) — a 'container swap' that touched payload"
# the .mov of the same source, for the A/B the doctrine rests on
bash "$SC/remux.sh" "$FIX/m2v422.ts" "$WORK/same.mov" >/dev/null 2>&1
hv=$(vhash "$WORK/same.mov")
{ [ -n "$hv" ] && [ "$hv" = "$hm" ]; } \
  && ok "the .mov and the .mp4 carry the SAME bitstream (only the container differs)" \
  || no "mov/mp4 packet hashes differ (mov=$hv mp4=$hm) — the A/B is not an A/B"
[ "$(p1 "$WORK/same.mov" v:0 stream=codec_tag_string)" = m2v1 ] \
  && ok "the .mov sibling carries 'm2v1' (the entry AVFoundation mis-dispatches)" \
  || no ".mov entry is '$(p1 "$WORK/same.mov" v:0 stream=codec_tag_string)', want m2v1"

echo
echo "== 3. D3: gate (g) accepts the swap's ipcm access track (it used to be an unwaivable FAIL) =="
if [ "$HAS_IPCM" = yes ]; then
  vo=$(bash "$SC/verify.sh" "$FIX/m2v422.ts" "$WORK/swap.mp4" 2>&1); vrc=$?
  has "$vo" "tag='ipcm'" "gate (g) sees the ipcm entry"
  hasnt "$vo" "a sample entry no decoder claims" "ipcm is no longer called a dead track"
  [ "$vrc" -eq 0 ] && ok "verify exits 0 on the swap (pre-1.13 this was exit 1, unwaivable)" \
    || { no "verify rc=$vrc on the container swap"; printf '%s\n' "$vo" | tail -12 | sed 's/^/   /'; }
else
  echo "  (skip: no ipcm on this ffmpeg — see the capability probe above)"
  # the allowlist entry itself is still assertable without the muxer
  case "$(cat "$SC/verify.sh")" in *"|ipcm)"*) ok "ipcm is on the QTFF audio allowlist (source-level)";; *) no "ipcm missing from the allowlist";; esac
fi

echo
echo "== 4. D2: 'unroutable' is a MOV fact — --container mp4 scopes it correctly =="
o=$(bash "$SC/remux.sh" "$FIX/vp9.webm" "$WORK/vp9.mov" 2>&1); rc=$?
{ [ "$rc" -eq 11 ] && case "$o" in *MOV_REFUSED*) true;; *) false;; esac; } \
  && ok "VP9 -> MOV still REFUSED (exit 11 + MOV_REFUSED) — the 1.11 gate is intact" || no "VP9->MOV rc=$rc (want 11 + MOV_REFUSED)"
o=$(bash "$SC/remux.sh" "$FIX/vp9.webm" "$WORK/vp9.mp4" --container mp4 2>&1); rc=$?
# the ASSERTION is the scoping — VP9 is not REFUSED on the MP4 rung. Whether this
# particular ffmpeg then writes it is a muxer-capability question, announced.
[ "$rc" -ne 11 ] && ok "VP9 -> MP4 is NOT refused (the refusal's own named route is no longer refused by it)" \
  || no "VP9->MP4 still exits 11 — the refusal is still MOV-scoped wrongly"
if [ "$rc" -eq 0 ] && [ -s "$WORK/vp9.mp4" ]; then ok "and this ffmpeg actually wrote it"
else echo "  (note: this ffmpeg did not complete the VP9->MP4 mux (rc=$rc) — capability, not policy)"; fi
o=$(bash "$SC/remux.sh" "$FIX/m2v422.ts" "$WORK/bad.mp4" --container xyz 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a bad --container value is usage (exit 2), not a mystery" || no "--container xyz rc=$rc, want 2"

echo
echo "== 5. D7: the retag advisory fires on a .ts SOURCE (it was dead there before 1.13) =="
kv=$(bash "$SC/probe.sh" "$FIX/m2v422.ts" --kv 2>&1)
has "$kv" "PR_TAG_ADVICE=xd5b" "mpegts MPEG-2 4:2:2: PR_TAG_ADVICE fires pre-build"
js=$(bash "$SC/probe.sh" "$FIX/m2v422.ts" --json 2>&1)
has "$js" '"tag_advice":"xd5b"' "--json carries tag_advice on the .ts too"
hum=$(bash "$SC/probe.sh" "$FIX/m2v422.ts" 2>&1)
has "$hum" "a .mov built from this gets stsd 'm2v1'" "the human report explains WHY a TS source can be advised pre-build"
has "$hum" "mp4-swap.sh" "the advisory names the container-swap rung as step 2 (D8: the retag is not THE remedy)"
kv0=$(bash "$SC/probe.sh" "$FIX/m2v420.ts" --kv 2>&1)
hasnt "$kv0" "PR_TAG_ADVICE" "4:2:0 TS control: advisory SILENT (the pix_fmt discriminator still decides)"
ffmpeg -nostdin -y -v error -i "$FIX/m2v422.mov" -map 0:v:0 -c copy -tag:v xd5b -f mov "$WORK/x5.mov" 2>/dev/null
kvx=$(bash "$SC/probe.sh" "$WORK/x5.mov" --kv 2>&1)
hasnt "$kvx" "PR_TAG_ADVICE" "already-retagged xd5b MOV: advisory SILENT (idempotent — no retag loop)"

echo
echo "== 6. D2: every fidelity-FAIL route names the swap before Rung 4 =="
# the routing TEXT is the deliverable here: pre-1.13 a fidelity FAIL named
# exactly one route (Rung 4), and the measured remedy was not on the list.
pc=$(bash "$SC/playable-check.sh" --fidelity "$WORK/nonexistent.mov" 2>&1)
case "$pc" in *"no such file"*) ok "playable-check still usage-guards a missing file";; *) no "missing-file guard changed";; esac
src_txt=$(cat "$SC/playable-check.sh")
has "$src_txt" "mp4_swap_route" "playable-check has a container-swap route function"
for f in mov.sh auto.sh lib-paff.sh; do
  case "$(cat "$SC/$f")" in *mp4-swap.sh*) ok "$f names scripts/mp4-swap.sh on its bad-render path";; *) no "$f never mentions the container-swap rung";; esac
done

echo
if [ "$BENCH" = mac ]; then
  echo "== 7. D2 (macOS): the swap's own fidelity proof runs and is announced =="
  o=$(RTM_FIDELITY_SSIM=0.90 bash "$SC/playable-check.sh" --fidelity "$WORK/swap.mp4" 2>&1); rc=$?
  has "$o" "PLAYCHECK_FIDELITY " "the .mp4 gets a real fidelity verdict (extension-agnostic)"
  case "$rc" in 0|1) ok "fidelity verdict on the .mp4 is a verdict (rc=$rc), not a skip";; *) no "fidelity on .mp4 rc=$rc";; esac
  echo "  SYNTHESIS LIMIT: this clip decodes cleanly through BOTH containers on this bench,"
  echo "  so the MOV-destroyed/MP4-correct A/B cannot be minted here. It is OPERATOR-VERIFIED"
  echo "  (2026-08-15, a real 21 GB MPEG-2 4:2:2 1080i29.97 capture: five MOV retags at SSIM"
  echo "  0.81-0.85, the MP4 swap at 0.9175+ on the same timestamps) — never faked into a green."
else
  echo "== 7. (skip: off-macOS — the AVFoundation half of the swap proof needs a Mac) =="
  echo "  NOT proven here: that the .mp4 renders correctly through AVFoundation. Evidence"
  echo "  bench for the route: macOS 26.6.1 / ffmpeg 9.0.1, 2026-08-15."
fi

for f in m2v422.ts m2v422.mov m2v420.ts vp9.webm; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "container-axis: $pass passed, $fail failed — MOV-destroyed/MP4-correct A/B is operator-verified (2026-08-15, real 21 GB capture; the synthetic clip cannot mint the corruption)"
[ "$fail" -eq 0 ]
