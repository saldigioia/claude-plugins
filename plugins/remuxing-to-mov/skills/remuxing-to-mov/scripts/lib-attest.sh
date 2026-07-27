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
