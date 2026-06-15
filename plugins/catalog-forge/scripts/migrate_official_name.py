#!/usr/bin/env python3
"""
migrate_official_name.py — collapse the name model to two fields.

Before: `name` (display) + an open-ended `name_variants` array that conflated the official
retailer title with superseded names (history).
After:  `name` (display) + `official_name` (the POS retailer's title, present only when an
official source exists). Superseded names are history → preserved in provenance, not a field.

Per product:
  * official (has metadata.json) → set `official_name = metadata.name`.
  * remove top-level `name_variants` (this is what currently fails the truth verifier).
  * preserve whatever `name_variants` held under `provenance._former_name_variants`
    (no silent disposal), and stamp `provenance._name_model`.

Dry-run by default. `--apply` writes a tar.gz backup of every touched canonical.json first.
metadata.json is never modified.

ORDER MATTERS: add `official_name` to the truth schema's `properties` BEFORE `--apply`,
otherwise the migrated records trip additionalProperties:false on the new field.
Suggested schema line:  "official_name": { "type": ["string", "null"] }
"""
from __future__ import annotations
import argparse, datetime, json, os, sys, tarfile

NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None


def find_products(root):
    out = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(("_", "."))]
        if "canonical.json" in fns:
            out.append(dp)
    return sorted(out)


def plan_one(pp):
    """Return a change dict for this product, or None if nothing to do."""
    c = load_json(os.path.join(pp, "canonical.json"))
    if c is None:
        return None
    meta = load_json(os.path.join(pp, "metadata.json"))
    official_title = meta.get("name") if meta else None
    has_variants = "name_variants" in c
    set_official = bool(official_title) and c.get("official_name") != official_title
    if not has_variants and not set_official:
        return None
    return {"dir": pp, "set_official_name": official_title if set_official else None,
            "drop_name_variants": c.get("name_variants") if has_variants else None,
            "is_official": meta is not None}


def apply_one(change):
    pp = change["dir"]
    fp = os.path.join(pp, "canonical.json")
    c = load_json(fp)
    if change["set_official_name"] is not None:
        c["official_name"] = change["set_official_name"]
    if "name_variants" in c:
        former = c.pop("name_variants")
        prov = c.setdefault("provenance", {})
        if former:
            prov["_former_name_variants"] = former
    c.setdefault("provenance", {})["_name_model"] = (
        f"{NOW[:10]}: two-field name model — display `name` + `official_name` (POS title); "
        "prior names preserved here, not in a name_variants array.")
    c["provenance"]["generated_at"] = NOW
    with open(fp, "w") as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(description="collapse name_variants → official_name (two-field model)")
    ap.add_argument("--root", required=True)
    ap.add_argument("--apply", action="store_true", help="write changes (backs up first)")
    a = ap.parse_args()
    root = os.path.abspath(a.root)

    changes = [ch for ch in (plan_one(pp) for pp in find_products(root)) if ch]
    set_n = sum(1 for ch in changes if ch["set_official_name"] is not None)
    drop_n = sum(1 for ch in changes if ch["drop_name_variants"] is not None)
    print(f"products needing change: {len(changes)}  (set official_name: {set_n}, "
          f"drop name_variants: {drop_n})")
    print("NOTE: add `\"official_name\": {\"type\":[\"string\",\"null\"]}` to the truth schema "
          "BEFORE --apply.\n")
    for ch in changes[:12]:
        rel = os.path.relpath(ch["dir"], root)
        print(f"  {rel}")
        if ch["set_official_name"] is not None:
            print(f"      official_name = {ch['set_official_name']!r}")
        if ch["drop_name_variants"] is not None:
            print(f"      drop name_variants {ch['drop_name_variants']!r} → provenance._former_name_variants")
    if len(changes) > 12:
        print(f"  … and {len(changes) - 12} more")

    if not a.apply:
        print("\nDRY-RUN — nothing written. Re-run with --apply (after the schema edit) to apply.")
        return 0
    if not changes:
        print("\nnothing to change.")
        return 0

    ts = NOW.replace(":", "").replace("-", "")[:15]
    bdir = os.path.join(root, "_pipeline")
    os.makedirs(bdir, exist_ok=True)
    bundle = os.path.join(bdir, f".bak_official_name_{ts}.tar.gz")
    with tarfile.open(bundle, "w:gz") as t:
        for ch in changes:
            fp = os.path.join(ch["dir"], "canonical.json")
            t.add(fp, arcname=os.path.relpath(fp, root))
    print(f"\nbackup → {os.path.relpath(bundle, root)}")
    for ch in changes:
        apply_one(ch)
    print(f"applied to {len(changes)} products. Now run: catalog verify --enforce")
    return 0


if __name__ == "__main__":
    sys.exit(main())
