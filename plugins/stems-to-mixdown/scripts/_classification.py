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
operators who name multitrack stems carelessly. See docs/research/2D for the
empirical confirmation and the recommended fix path (rename at the source —
e.g., the demucs sibling skill — rather than widen the regex here).
"""

from __future__ import annotations

import re

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
