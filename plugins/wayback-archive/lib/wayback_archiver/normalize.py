"""
Image classification and semantic renaming.

Naming scheme:
    front.png                   — flat/product front view
    back.png                    — flat/product back view
    front-male.png              — on male model, front
    back-female.png             — on female model, back
    detail.png, detail-2.png    — editorial / detail / other shots
    side.png                    — side view

Canonical implementation — replaces 8 duplicated copies across scripts.
"""
from __future__ import annotations

import re
from pathlib import Path

# Valid image extensions for scanning directories
IMAGE_EXTENSIONS = frozenset(('.png', '.jpg', '.jpeg', '.tif', '.tiff', '.webp'))


def classify(filename: str) -> tuple[str | None, str | None]:
    """
    Extract (angle, model) from a filename.

    angle: front | back | side | None
    model: male | female | None
    """
    name = filename.upper()

    # Angle detection
    angle = None
    if "FRONT" in name:
        angle = "front"
    elif "BACK" in name:
        angle = "back"
    elif "SIDE" in name or "RIGHT" in name:
        angle = "side"

    # Model gender detection
    # Careful: "FRONT-F" / "BACK-M" / "-FEMALE" / "-MALE"
    # but NOT "FLEECE" / "FLAME" / "FACEMASK" etc.
    model = None
    if re.search(r'[-_ ]FEMALE', name):
        model = "female"
    elif re.search(r'[-_ ]MALE', name):
        model = "male"
    elif re.search(r'[-_]F[-_.]', name) or name.endswith("-F"):
        model = "female"
    elif re.search(r'[-_]M[-_.]', name) or name.endswith("-M"):
        # Exclude false positives: "_M-BLACK" means "mens cut" not "on male model"
        # But "471272-BLACK-FRONT-M.png" means male model
        if re.search(r'(?:FRONT|BACK)[-_]M(?:[-_.]|$)', name):
            model = "male"
        elif re.search(r'[-_]M[-_.]', name) and not re.search(
            r'[-_]M[-_](?:BLACK|BLUE|GREEN|GREY|LS|SS)', name
        ):
            model = "male"

    return angle, model


def build_new_name(
    angle: str | None,
    model: str | None,
    ext: str,
    used: set[str],
) -> str:
    """Build a semantic filename, handling collisions with sequence numbers."""
    if angle and model:
        base = f"{angle}-{model}"
    elif angle:
        base = angle
    else:
        base = "detail"

    candidate = f"{base}{ext}"
    if candidate not in used:
        return candidate

    n = 2
    while True:
        candidate = f"{base}-{n}{ext}"
        if candidate not in used:
            return candidate
        n += 1


def _sort_key(f: Path) -> tuple[int, str]:
    """Sort images so angle+model files get clean names first."""
    a, m = classify(f.stem)
    priority = 0 if (a and m) else (1 if a else 2)
    return (priority, f.name.lower())


def rename_batch(files: list[Path], existing_used: set[str] | None = None) -> list[tuple[Path, Path]]:
    """
    Rename a list of image files using the semantic naming scheme.

    Returns list of (old_path, new_path) pairs for files that were renamed.
    Uses a tmp file to avoid collisions during rename.
    """
    if not files:
        return []

    used = set(existing_used) if existing_used else set()
    renames = []

    for f in sorted(files, key=_sort_key):
        a, m = classify(f.stem)
        ext = f.suffix.lower()
        new_name = build_new_name(a, m, ext, used)
        used.add(new_name)

        if f.name != new_name:
            tmp = f.with_suffix(f.suffix + ".tmp_rename")
            f.rename(tmp)
            new_path = f.parent / new_name
            tmp.rename(new_path)
            renames.append((f, new_path))

    return renames


def list_images(directory: Path) -> list[Path]:
    """List all image files in a directory, sorted."""
    if not directory.exists():
        return []
    return sorted(
        f for f in directory.iterdir()
        if f.suffix.lower() in IMAGE_EXTENSIONS
    )
