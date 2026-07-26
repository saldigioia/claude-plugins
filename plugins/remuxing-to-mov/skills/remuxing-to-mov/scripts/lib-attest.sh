# lib-attest.sh — operator consent strings, defined once (QTFF audit round 5).
# Sourced by the scripts that require verbatim operator attestation. These are
# load-bearing constants: exact match only, no fuzzy accept, and the string must
# originate from the operator — no script or session ever supplies it on the
# operator's behalf (Rung-4 protocol / waiver protocol in SKILL.md).
#
# Waiver protocol (5-4c): accepting a recorded gate-failure waiver for ONE file
# and ONE exact failure signature. Distinct from the Rung-4 re-encode
# attestation (5-3), which will live here too when rung4.sh lands.
# shellcheck disable=SC2034  # consumed by sourcing scripts
RTM_WAIVER_ATTEST="I accept this waiver; the recorded evidence proves this gate failure benign for this file."
