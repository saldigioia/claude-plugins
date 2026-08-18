# lib-attest.sh — operator consent strings, defined once (QTFF audit round 5).
# Sourced by the scripts that require verbatim operator attestation. These are
# load-bearing constants: exact match only, no fuzzy accept, and the string must
# originate from the operator — no script or session ever supplies it on the
# operator's behalf (Rung-4 protocol / waiver protocol in SKILL.md).
#
# Waiver protocol (5-4c): accepting a recorded gate-failure waiver for ONE file
# and ONE exact failure signature.
# shellcheck disable=SC2034  # consumed by sourcing scripts
RTM_WAIVER_ATTEST="I accept this waiver; the recorded evidence proves this gate failure benign for this file."
# Rung-4 protocol (5-3): consenting to a re-encode — the one operation whose
# output is no longer true source material. rung4.sh refuses without it.
# shellcheck disable=SC2034  # consumed by sourcing scripts
RTM_RUNG4_ATTEST="I understand this re-encodes the video and the output is no longer true source material."

# --- attested builder-precondition override (2026-08-18) ----------------------
# The PROVENANCE job of 2026-08-18 (23.7 GB PAFF capture, 11 displaced-timestamp
# junctions) was refused by a builder PRECONDITION and had to be done by hand —
# the model was wrong for that file and the operator could prove it, but the
# only route past the gate was outside the plugin entirely (no sidecar, no
# record). This extends the waiver/rung4 pattern to builder preconditions:
# verbatim operator string, exact match only, sidecar written, and the override
# skips ONLY the named precondition — every output gate still runs (attestation
# skips the precondition, never the evidence).
#
# precond_attest GATE_NAME SCRIPT OUTPUT [MEASURED ...]
#   Checks RTM_PRECOND_ATTEST for the verbatim string
#     I attest: override <GATE_NAME> in <SCRIPT>; I have independent evidence the model is wrong for this file
#   Present + exact: announces loudly, writes <OUTPUT>.precond-waiver.txt (gate,
#   script, date, operator string, the measured values that would have refused
#   — mirroring waiver.sh's one-key-per-line sidecar shape), emits the
#   machine line  RTM_PRECOND_WAIVER gate= script= sidecar=  and returns 0.
#   Absent or a near-miss: returns 1 (the gate refuses as before; the caller's
#   refusal text names the route via precond_attest_route below).
precond_attest () {
  local gate="${1:?precond_attest needs GATE_NAME}" script="${2:?precond_attest needs SCRIPT}" out="${3:?precond_attest needs OUTPUT}"
  shift 3
  local want="I attest: override $gate in $script; I have independent evidence the model is wrong for this file"
  [ "${RTM_PRECOND_ATTEST:-}" = "$want" ] || return 1
  local sc="$out.precond-waiver.txt" m
  echo "** PRECONDITION OVERRIDE ATTESTED: gate $gate in $script."
  echo "**   The operator attests to independent evidence that the model behind this"
  echo "**   precondition is wrong for this file. The precondition is SKIPPED; every"
  echo "**   output gate still runs — attestation skips the precondition, never the"
  echo "**   evidence. Recorded in a sidecar for the audit trail."
  {
    printf 'precond_waiver_format: 1\n'
    printf 'gate: %s\n' "$gate"
    printf 'script: %s\n' "$script"
    printf 'date: %s\n' "$(date +%F)"
    printf 'attestation: %s\n' "$want"
    printf 'measured:\n'
    for m in "$@"; do printf '  %s\n' "$m"; done
  } > "$sc.part" && mv -f "$sc.part" "$sc"
  echo "**   sidecar recorded: $sc"
  echo "RTM_PRECOND_WAIVER gate=$gate script=$script sidecar=$sc"   # machine-readable (additive, 2026-08-18)
  return 0
}

# precond_attest_route GATE_NAME SCRIPT — the one refusal postscript naming the
# attestation route WITH the exact string (unlike rung4's consent-to-destroy,
# printing this string is deliberate: the gate protects a MODEL, not source
# material, and the operator must be able to see exactly what to attest to).
precond_attest_route () {
  echo "   Operator override (recorded, exact-match only): rerun with RTM_PRECOND_ATTEST"
  echo "   set to exactly:"
  echo "     I attest: override ${1:-?} in ${2:-?}; I have independent evidence the model is wrong for this file"
  echo "   A sidecar <OUT>.precond-waiver.txt records the override; every output gate"
  echo "   still runs — attestation skips the precondition, never the evidence."
  return 0
}
