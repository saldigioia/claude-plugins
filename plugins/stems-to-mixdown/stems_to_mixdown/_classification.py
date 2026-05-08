"""Shared filename-classification rules for the stems-to-mixdown skill.

A single CLASSIFICATION_RULES list with a stable label order. Importers should
treat this module as the source of truth — if a label or regex moves here, no
other script should be carrying its own copy. analyze.py / identify.py /
import_session_info.py historically each had a near-duplicate; that drift is
now eliminated.

Public API:
- CLASSIFICATION_RULES: list[tuple[label, compiled regex]]
- classify_by_filename(name): -> str (one of: vocal, drums, bass, guitar, keys, fx, other)
- normalize_filename(name): -> str (the separator-flattened form regexes match against)

The trailing word-boundary (`\\b`) in each regex deliberately matches singular
forms only — `vocals.wav` and `drums.wav` will NOT match `\\bvocal\\b` /
`\\bdrum\\b` because Python's `\\b` requires a word/non-word transition that a
trailing `s` doesn't provide. This is intentional. Strictness protects
operators who name multitrack stems carelessly. The recommended fix when an
upstream tool produces plural names is to rename at the source rather than
widen the regex here.
"""

from __future__ import annotations

import re
from pathlib import Path

CLASSIFICATION_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("vocal",  re.compile(r"\b(vox|vocal|lead|bg|chorus|adlib|harm|hook|rap|verse)\b", re.IGNORECASE)),
    ("drums",  re.compile(r"\b(drum|kick|snare|hat|tom|perc|cymbal|ride|crash|clap|shaker|conga|808kit)\b", re.IGNORECASE)),
    ("bass",   re.compile(r"(\bbass\b|\bsub\b|\b808\b)", re.IGNORECASE)),
    ("guitar", re.compile(r"\b(gtr|guitar|acoustic|elec)\b", re.IGNORECASE)),
    ("keys",   re.compile(r"\b(key|keys|piano|rhodes|synth|pad|organ|wurli|wurlitzer)\b", re.IGNORECASE)),
    ("fx",     re.compile(r"\b(fx|riser|impact|sweep|noise|whoosh|stinger)\b", re.IGNORECASE)),
]

# identify.py historically separated "informative" from "classification";
# the patterns are identical to CLASSIFICATION_RULES minus the labels and
# (in identify.py's older copy) without `808kit`. Re-derive from the canonical
# list so the two stay locked together.
INFORMATIVE_PATTERNS: list[re.Pattern[str]] = [pattern for _, pattern in CLASSIFICATION_RULES]


def normalize_filename(name: str) -> str:
    """Flatten separators so `\\b` boundaries fire across `_`, `-`, `.`."""
    return re.sub(r"[_\-.]+", " ", name)


def classify_by_filename(filename: str) -> str:
    """Return one of: vocal, drums, bass, guitar, keys, fx, other.

    `filename` should be the bare stem (no extension), or a path-like string;
    `normalize_filename` is applied before matching.
    """
    normalized = normalize_filename(filename)
    for label, pattern in CLASSIFICATION_RULES:
        if pattern.search(normalized):
            return label
    return "other"


# Master-reference auto-detection -------------------------------------------
#
# When the operator drops the released version of the song into the same
# folder as the stems (a common archival layout), identify and analyze should
# notice and propose using it as the master reference (Cmd 19) — not silently
# sum it as if it were one more stem.
#
# Patterns are intentionally narrow: a filename qualifies only if (a) it
# matches one of the master-vocabulary tokens AND (b) it doesn't classify as
# a stem. A file like `vocal_master.wav` is a stem (a vocal master mix-bus
# bounce, perhaps) — not the released master.
MASTER_NAME_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"\bmaster(?:ed|ing)?\b", re.IGNORECASE),
    re.compile(r"\bfinal(?:_?mix)?\b", re.IGNORECASE),
    re.compile(r"\breleased?\b", re.IGNORECASE),
    re.compile(r"\breference\b", re.IGNORECASE),
    re.compile(r"\bbounce_final\b", re.IGNORECASE),
]


def looks_like_master(filename: str) -> bool:
    """Filename suggests a released master, not a stem.

    Two-part test: master-vocabulary token present AND the bare name does NOT
    classify as a stem (vocal/drums/bass/etc.). Returns True only when both
    conditions hold; the conservative default lets analyze sum the file as a
    regular stem when the signals are ambiguous.
    """
    stem_name = Path(filename).stem
    normalized = normalize_filename(stem_name)
    if not any(p.search(normalized) for p in MASTER_NAME_PATTERNS):
        return False
    # Don't claim a stem (e.g. "vocal_master.wav") as the released master.
    if classify_by_filename(stem_name) != "other":
        return False
    return True
