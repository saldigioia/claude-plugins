#!/usr/bin/env python3
"""
catalog.py — the single entry point for catalog-forge.

A thin, path-driven layer over the EXISTING engines: the truth-root verifier
(tools/verify/verify_all.py) and the work-dir pipeline (collection_pipeline.py). It adds only
mechanical conveniences; it never re-implements the verifier and never makes a judgment call.

The list of collections and their rules live in the truth root (the schema's `collection`
enum + verify_all.py) — the single source. This tool keeps no copy of that; `config.json`
holds only the default truth-root path.

Subcommands
  verify     One-command verify against the truth-root 4-axis verifier. Auto-stages the
             work dir (one symlink) so you never run the manual dance again. Read-only.
  scaffold   Create a new product or collection skeleton. Mechanical.
  enrich     PROPOSE-ONLY review queue (dates / same-product / identical-file). Never writes
             to a product file. The curator confirms.
  sidecars   Validate metadata/image_sources/curation against their schemas. Read-only.
  registry   list (collections the truth root knows) / plan (edits to register a new one).

Honors: metadata.json is never written; judgment is proposed, never applied; only `verify`
(read-only) and `registry` touch the truth root.
"""
from __future__ import annotations
import argparse, datetime, json, os, re, subprocess, sys, tempfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(HERE)
SCHEMA_DIR = os.path.join(PLUGIN_ROOT, "schema")
TEMPLATE_DIR = os.path.join(PLUGIN_ROOT, "templates")
CONFIG_PATH = os.path.join(SCHEMA_DIR, "config.json")
FALLBACK_TRUTH = "/Volumes/PRO-G40/collections"
NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
IMG_EXT = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".tif", ".tiff", ".psd", ".bmp")

# Per-CDN master-rendition recipes (mirrors the canonical-collections skill's table). Each
# entry: how to reach the master image and the curl-impersonate profile. `transform` (when
# present) is a deterministic URL rewrite the tool can apply itself; the rest need a JSON or
# headless step and are printed as instructions. `non_master` flags a rendition below the
# ceiling for the liveness sweep. Acquisition stays curator-gated: gallery isolation and
# "does this belong to this product/colourway" remain judgment calls.
CDN_RECIPES = {
    "i.ebayimg.com": {
        "master": "s-l1600 (1600 px cap)", "impersonation": "safari17_0",
        "transform": (r"/s-l\d+\.", "/s-l1600."),
        "non_master": r"/s-l(?!1600)\d+\.",
        "isolation": "isolate the listing's own gallery via VIImageType \"Picture N of M\"; reject cross-sell",
    },
    "i.etsystatic.com": {
        "master": "il_fullxfull.<id>", "impersonation": "safari17_0 (DataDome)",
        "transform": (r"/il_\d+x[Nx\d]+\.", "/il_fullxfull."),
        "non_master": r"/il_(?!fullxfull)\w+\.",
        "isolation": "use only this listing's image ids",
    },
    "u-mercari-images.mercdn.net": {
        "master": "bare …/<item>_<N>.jpg", "impersonation": "safari17_0",
        "transform": (r"\?.*$", ""), "non_master": r"\?",
        "isolation": "one item id; sequential _<N> are that item's gallery",
    },
    "media-photos.depop.com": {
        "master": "P0.jpg (P0 = 1280 master; P1+ smaller)", "impersonation": "chrome120",
        "transform": (r"/P\d+\.", "/P0."), "non_master": r"/P(?!0\.)\d+\.",
        "isolation": "P0..Pn are one listing's gallery",
    },
    "media-assets.grailed.com": {
        "master": "bare object — URL from __NEXT_DATA__ photos[].url", "impersonation": "safari17_0",
        "isolation": "read photos[] from the listing's __NEXT_DATA__",
    },
    "cdn.shopify.com": {
        "master": "<product>.json → images[].src ; append ?format=png for lossless",
        "impersonation": "safari17_0",
        "isolation": "the product .json lists exactly that product's gallery",
    },
    "cdninstagram.com": {  # matched as a host suffix
        "master": "/p/<code>/embed/captioned/ display_url (1080; NOT og:image)",
        "impersonation": "chrome120",
        "isolation": "one post code; carousel children are that post",
    },
    "gem.app": {
        "master": "JS-WAF → headless; gallery is often eBay-hosted (use the eBay item instead)",
        "impersonation": "Playwright",
        "isolation": "prefer the underlying eBay item if present",
    },
}


def match_recipe(url):
    """Return (host_key, recipe) for the first CDN whose host the URL belongs to, else (None, None)."""
    try:
        from urllib.parse import urlparse
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        return None, None
    for key, rec in CDN_RECIPES.items():
        if host == key or host.endswith("." + key) or host.endswith(key):
            return key, rec
    return None, None


# ----------------------------------------------------------------- helpers

def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None


def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")


def is_hidden(name):
    return name.startswith("_") or name.startswith(".")


def truth_root(a):
    return getattr(a, "truth_root", None) or (load_json(CONFIG_PATH) or {}).get("truth_root_default") or FALLBACK_TRUTH


def schema_enum(truth):
    sd = load_json(os.path.join(truth, "schema", "canonical-3.1.schema.json")) or {}
    try:
        return sd["properties"]["collection"]["enum"]
    except Exception:
        return []


def find_products(root):
    """Yield (sublevel_or_none, product_dir_name, abspath) for every dir holding
    canonical.json, skipping _*/.* path components."""
    out = []
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not is_hidden(d)]
        if "canonical.json" in fns:
            parts = os.path.relpath(dp, root).split(os.sep)
            sub = parts[-2] if len(parts) >= 2 else None
            out.append((sub, os.path.basename(dp), dp))
    return sorted(out, key=lambda t: t[2])


def sniff_collection(root):
    for _, _, pp in find_products(root):
        c = load_json(os.path.join(pp, "canonical.json"))
        if c and c.get("collection"):
            return c["collection"]
    return None


# ----------------------------------------------------------------- verify

def cmd_verify(a):
    truth = truth_root(a)
    root = os.path.abspath(a.root)
    coll = a.collection or sniff_collection(root)
    if not coll:
        sys.exit("ERR: could not determine collection; pass --collection")
    verifier = os.path.join(truth, "tools", "verify", "verify_all.py")
    if not os.path.exists(verifier):
        sys.exit(f"ERR: truth-root verifier not found at {verifier} (set --truth-root)")
    enum = schema_enum(truth)
    if enum and coll not in enum:
        print(f"[verify] NOTE: {coll!r} is not in the truth schema enum yet — the verifier "
              f"will report 0 for it. Register it: catalog registry plan --name {coll!r}",
              file=sys.stderr)

    # Stage the work dir as <STAGE>/<Collection> with ONE symlink so the verifier's glob
    # resolves through it. Works for flat and era/season collections alike.
    stage = tempfile.mkdtemp(prefix="catalog_verify_")
    link = os.path.join(stage, coll)
    os.symlink(root, link)
    report_dir = a.report_dir or os.path.join(root, "_pipeline", "_review", "verify")
    os.makedirs(report_dir, exist_ok=True)

    cmd = [sys.executable, verifier, "--target", stage, "--report-dir", report_dir]
    if a.enforce:
        cmd.append("--enforce")
    print(f"[verify] {coll!r} via truth verifier (staged at {stage})", file=sys.stderr)
    rc = subprocess.run(cmd).returncode
    try:
        os.unlink(link)
        os.rmdir(stage)
    except OSError:
        pass
    print(f"[verify] reports → {report_dir}", file=sys.stderr)
    return rc


# ----------------------------------------------------------------- scaffold

def cmd_scaffold(a):
    root = os.path.abspath(a.root)
    if a.what == "collection":
        os.makedirs(root, exist_ok=True)
        _write_checklist(root, a.name)
        print(f"[scaffold] collection work dir ready: {root}")
        print(f"[scaffold] wrote CHECKLIST.md (the playbook, instantiated for {a.name})")
        print(f"[scaffold] when ready to promote: catalog registry plan --name {a.name!r}")
        return 0

    # product — caller passes the exact folder grammar: Name (Color) [Tag]...
    folder = a.name
    parent = os.path.join(root, a.era) if a.era else root
    pdir = os.path.join(parent, folder)
    if os.path.exists(pdir):
        sys.exit(f"ERR: refusing to overwrite existing dir: {pdir}")
    coll = a.collection or sniff_collection(root) or "__COLLECTION__"
    os.makedirs(pdir)
    stub = open(os.path.join(TEMPLATE_DIR, "canonical.stub.json")).read()
    core = re.split(r"\s*[\(\[]", folder)[0].strip()
    stub = (stub.replace("__SLUG__", slugify(folder)).replace("__FOLDER__", folder)
                .replace("__NAME__", core).replace("__COLLECTION__", coll)
                .replace("__ERA__", a.era or "").replace("__NOW__", NOW))
    d = json.loads(stub)
    if not a.era:
        d.pop("era", None)
    with open(os.path.join(pdir, "canonical.json"), "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"[scaffold] product stub created: {pdir}")
    print("[scaffold] next: acquire master imagery, trace sources, then catalog-finalize.")
    return 0


def _write_checklist(target, coll):
    txt = f"""# Finalization checklist — {coll}

From the Collection Finalization Playbook. Mechanical steps auto-apply; **judgment steps
propose — the curator confirms.**

- [ ] Phase 0  Snapshot + baseline audit
- [ ] Phase 1  Schema & image integrity → `catalog audit` 0 errors
- [ ] Phase 2  Image acquisition (master rendition)
- [ ] Phase 3  Source tracing → every image has a URL/provenance
- [ ] Phase 4  Visual identity & belonging → `catalog review` (curator verdicts)
- [ ] Phase 5  Redundancy pruning → propose, quarantine on confirm
- [ ] Phase 6  De-duplication & merges → `catalog enrich --what dupes` (curator confirms)
- [ ] Phase 7  Standardization & naming → propose, apply on confirm
- [ ] Phase 8  Sidecar completion → `catalog sidecars` clean
- [ ] Phase 9  Finalize → `catalog-finalize`
- [ ] Verify   `catalog verify --enforce` → fail=0
- [ ] Promote  `catalog promote` (gated; writes into the truth root)

Done = the truth-root 4-axis verifier passes for every product.
"""
    with open(os.path.join(target, "CHECKLIST.md"), "w") as f:
        f.write(txt)


# ----------------------------------------------------------------- enrich (PROPOSE ONLY)

# Verdict options are a function of entry type, so they live here once — not on every entry.
VERDICT_OPTIONS = {
    "date": ["accept", "set:<ISO>", "leave-null"],
    "same_product": ["merge->keeper", "keep-separate"],
    "identical_file": ["merge->keeper", "cross-link", "coincidental-press-shot", "keep-separate"],
}


def cmd_enrich(a):
    root = os.path.abspath(a.root)
    prods = find_products(root)
    what = set(a.what)
    entries = []

    if {"dates", "all"} & what:
        # High confidence only: propose a date solely from POS truth (metadata.first_seen).
        # Era-year guesses were noise; leave undated products for the curator's semantics call.
        for sub, name, pp in prods:
            c = load_json(os.path.join(pp, "canonical.json")) or {}
            if c.get("date"):
                continue
            fs = (load_json(os.path.join(pp, "metadata.json")) or {}).get("first_seen")
            if fs:
                entries.append({"type": "date", "era": sub, "product": name,
                                "proposed": fs, "basis": "metadata.first_seen", "verdict": None})

    if {"dupes", "all"} & what:
        by_cit = defaultdict(set)  # (key, value) -> {(era, product)}
        for sub, name, pp in prods:
            c = load_json(os.path.join(pp, "canonical.json")) or {}
            for k, vals in (c.get("citations") or {}).items():
                for v in (vals if isinstance(vals, list) else [vals]):
                    by_cit[(k, v)].add((sub, name))
        for (k, v), occ in sorted(by_cit.items()):
            if len(occ) > 1:
                entries.append({"type": "same_product", "citation_key": k, "citation_value": v,
                                "products": [{"era": e, "product": n} for e, n in sorted(occ)],
                                "verdict": None})

    if {"identical", "all"} & what:
        by_sha = defaultdict(list)  # sha -> [(era, product, filename)]
        for sub, name, pp in prods:
            c = load_json(os.path.join(pp, "canonical.json")) or {}
            for im in c.get("images", []):
                if im.get("sha256"):
                    by_sha[im["sha256"]].append((sub, name, im.get("filename")))
        for sha, occ in by_sha.items():
            if len({(e, n) for e, n, _ in occ}) > 1:
                entries.append({"type": "identical_file", "sha256": sha,
                                "occurrences": [{"era": e, "product": n, "filename": f} for e, n, f in occ],
                                "verdict": None})

    queue = {"generated_at": NOW, "root": root, "tool": "catalog enrich",
             "discipline": "PROPOSE ONLY — set each entry's verdict before any apply",
             "verdict_options": VERDICT_OPTIONS,
             "counts": {t: sum(1 for e in entries if e["type"] == t)
                        for t in ("date", "same_product", "identical_file")},
             "entries": entries}
    out = a.out or os.path.join(root, "_pipeline", "_review", "queue.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(queue, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(json.dumps({"queue": out, "counts": queue["counts"], "total_entries": len(entries)}, indent=2))
    return 0


# ----------------------------------------------------------------- sidecars (read-only)

def cmd_sidecars(a):
    from jsonschema import Draft202012Validator
    root = os.path.abspath(a.root)
    validators = {n: Draft202012Validator(load_json(os.path.join(SCHEMA_DIR, f"{n}.schema.json")))
                  for n in ("metadata", "image_sources", "curation")}
    checked = defaultdict(int)
    failures = []
    for _, name, pp in find_products(root):
        for sc, val in validators.items():
            fp = os.path.join(pp, f"{sc}.json")
            if not os.path.exists(fp):
                continue
            checked[sc] += 1
            d = load_json(fp)
            if d is None:
                failures.append({"product": name, "sidecar": sc, "error": "unreadable / invalid JSON"})
                continue
            for e in val.iter_errors(d):
                failures.append({"product": name, "sidecar": sc,
                                 "path": "/".join(str(x) for x in e.absolute_path), "error": e.message[:160]})
    print(json.dumps({"root": root, "checked": dict(checked), "failures": failures,
                      "summary": f"{sum(checked.values())} sidecars checked, {len(failures)} problems"}, indent=2))
    return 1 if (failures and a.enforce) else 0


# ----------------------------------------------------------------- registry (reads the truth root)

def cmd_registry(a):
    truth = truth_root(a)
    if a.action == "list":
        enum = schema_enum(truth)
        if not enum:
            print(f"(no collections found — truth root not reachable at {truth}; set --truth-root)")
            return 0
        print(f"Collections the truth root knows ({truth}/schema canonical-3.1 enum):")
        for n in enum:
            print(f"  {n}")
        return 0

    # plan: the exact edits to register a new collection. Shape comes from your flags,
    # not from a stored copy of the truth root.
    name = a.name
    if not name:
        sys.exit("ERR: --name required for plan")
    pattern = f"{name}/*/*/canonical.json" if a.levels == 2 else f"{name}/*/canonical.json"
    print(f"# Register collection: {name}\n")
    print(f"1. schema/canonical-3.1.schema.json  → add {name!r} to the `collection` enum")
    if a.levels == 2:
        print("   (and confirm the sublevel field — `era`/`season` — is supported)")
    print(f"2. tools/verify/verify_all.py        → COLLECTIONS[{name!r}] = "
          f"{{'pattern': {pattern!r}, 'folder_grammar': 'tour'}}")
    if a.sub_floor_ok:
        print(f"   → add {name!r} to SUB_FLOOR_OK")
    if a.empty_images_ok:
        print(f"   → add {name!r} to EMPTY_IMAGES_OK")
    print(f"3. tools/unify/build_exports_from_canonical.py → add {name!r} to its COLLECTIONS")
    print(f"4. tools/unify/build_db_from_canonical.py      → add {name!r} to its COLLECTIONS")
    print(f"5. tools/docs/build_collection_readmes.py      → add {name!r} to its COLLECTIONS")
    print("\nThen: make all && make verify")
    return 0


# ----------------------------------------------------------------- fetch (advisory; read-only)

def cmd_fetch(a):
    """Resolve a listing/image URL to its master rendition using the per-CDN recipes.

    Read-only and advisory by default: it computes the master URL where the rewrite is
    deterministic (eBay/Etsy/Mercari/Depop) and prints the recipe + curl-impersonate profile
    for the rest. It does NOT download — long network jobs belong in the curator's own
    terminal as resumable scripts, and gallery isolation + belonging stay curator-gated.
    """
    import re as _re
    url = a.url
    host, rec = match_recipe(url)
    if not rec:
        print(json.dumps({"url": url, "recognized": False,
                          "note": "No CDN recipe matched this host. Add one to CDN_RECIPES, "
                                  "or trace the source by hand and record provenance."}, indent=2))
        return 0

    master_url = None
    tr = rec.get("transform")
    if tr:
        pat, repl = tr
        candidate = _re.sub(pat, repl, url)
        if candidate != url:
            master_url = candidate

    out = {
        "url": url,
        "host": host,
        "recognized": True,
        "master_rendition": rec["master"],
        "master_url": master_url,
        "deterministic_rewrite": bool(master_url),
        "impersonation": rec["impersonation"],
        "gallery_isolation": rec["isolation"],
        "discipline": "ADVISORY — does not download. Acquisition is mechanical; "
                      "gallery isolation and product/colourway belonging stay curator verdicts.",
        "next_steps": [
            "Confirm this image belongs to THIS product's own gallery (reject cross-sell).",
            "SHA-256-dedupe against images already on disk before adding.",
            f"Fetch in your terminal with curl --impersonate {rec['impersonation']} "
            f"(resumable script) — then add the row to image_sources.json with its provenance.",
            "Unreachable but known sources → image_sources.unavailable_sources[] (never dropped).",
        ],
    }
    if not master_url and not tr:
        out["next_steps"].insert(0, "This host needs a JSON or headless step (see master_rendition) "
                                    "— no deterministic URL rewrite.")
    print(json.dumps(out, indent=2))
    return 0


# ----------------------------------------------------------------- sweep (flag-only liveness)

def cmd_sweep(a):
    """Citation liveness + rendition-ceiling sweep. Flag-only — never edits a record.

    Offline (default): walk every canonical.json under --root and flag image URLs that are
    below the master-rendition ceiling per the CDN recipes. Online (--online): also issue a
    light ranged GET per download_url and flag non-2xx / unreachable. Writes a report and
    prints a summary. Schedulable; safe to run over the whole truth root.
    """
    import re as _re
    root = os.path.abspath(a.root) if a.root else truth_root(a)
    prods = find_products(root)
    non_master, dead = [], []
    checked_urls = 0

    def urls_of(c):
        for im in (c.get("images") or []):
            u = im.get("download_url") or im.get("url")
            if u:
                yield im.get("filename"), u

    for sub, name, pp in prods:
        c = load_json(os.path.join(pp, "canonical.json")) or {}
        for fn, u in urls_of(c):
            checked_urls += 1
            host, rec = match_recipe(u)
            nm = rec.get("non_master") if rec else None
            if nm and _re.search(nm, u):
                non_master.append({"era": sub, "product": name, "filename": fn,
                                   "url": u, "host": host, "want": rec["master"]})

    if a.online:
        import urllib.request
        for sub, name, pp in prods:
            c = load_json(os.path.join(pp, "canonical.json")) or {}
            for fn, u in urls_of(c):
                req = urllib.request.Request(u, method="GET", headers={
                    "Range": "bytes=0-0",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                                  "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"})
                try:
                    with urllib.request.urlopen(req, timeout=a.timeout) as r:
                        if r.status >= 400:
                            dead.append({"era": sub, "product": name, "filename": fn,
                                         "url": u, "status": r.status})
                except Exception as e:
                    dead.append({"era": sub, "product": name, "filename": fn,
                                 "url": u, "error": str(e)[:120]})

    report = {"generated_at": NOW, "root": root, "tool": "catalog sweep",
              "discipline": "FLAG-ONLY — never edits a record",
              "online": bool(a.online), "products": len(prods), "urls_checked": checked_urls,
              "counts": {"non_master": len(non_master), "dead_or_unreachable": len(dead)},
              "non_master": non_master, "dead_or_unreachable": dead}
    out = a.out or os.path.join(root, "_pipeline", "_review", "sweep.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(json.dumps({"report": out, "products": len(prods), "urls_checked": checked_urls,
                      "counts": report["counts"]}, indent=2))
    return 1 if (a.enforce and (non_master or dead)) else 0


# ----------------------------------------------------------------- cli

def main():
    ap = argparse.ArgumentParser(prog="catalog", description="catalog-forge engine")
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("verify", help="one-command truth-root verify (auto-staging)")
    v.add_argument("--root", required=True)
    v.add_argument("--collection")
    v.add_argument("--truth-root")
    v.add_argument("--report-dir")
    v.add_argument("--enforce", action="store_true")
    v.set_defaults(fn=cmd_verify)

    s = sub.add_parser("scaffold", help="create a product or collection skeleton")
    s.add_argument("what", choices=["product", "collection"])
    s.add_argument("--root", required=True)
    s.add_argument("--name", required=True, help="product folder (Name (Color) [Tag]) or collection name")
    s.add_argument("--era", help="era/season subfolder for a product")
    s.add_argument("--collection")
    s.set_defaults(fn=cmd_scaffold)

    e = sub.add_parser("enrich", help="PROPOSE-ONLY review queue (dates/dupes/identical)")
    e.add_argument("--root", required=True)
    e.add_argument("--what", nargs="+", default=["all"], choices=["dates", "dupes", "identical", "all"])
    e.add_argument("--out")
    e.set_defaults(fn=cmd_enrich)

    sc = sub.add_parser("sidecars", help="validate metadata/image_sources/curation (read-only)")
    sc.add_argument("--root", required=True)
    sc.add_argument("--enforce", action="store_true")
    sc.set_defaults(fn=cmd_sidecars)

    r = sub.add_parser("registry", help="list collections the truth root knows / plan a new one")
    r.add_argument("action", choices=["list", "plan"])
    r.add_argument("--name")
    r.add_argument("--truth-root")
    r.add_argument("--levels", type=int, default=1, choices=[1, 2], help="2 = era/season sublevel")
    r.add_argument("--sub-floor-ok", action="store_true", dest="sub_floor_ok")
    r.add_argument("--empty-images-ok", action="store_true", dest="empty_images_ok")
    r.set_defaults(fn=cmd_registry)

    f = sub.add_parser("fetch", help="resolve a URL to its master rendition (advisory; no download)")
    f.add_argument("--url", required=True)
    f.add_argument("--root", help="optional work dir (for context only; fetch writes nothing)")
    f.set_defaults(fn=cmd_fetch)

    sw = sub.add_parser("sweep", help="citation liveness + rendition-ceiling sweep (flag-only)")
    sw.add_argument("--root", help="defaults to the truth root")
    sw.add_argument("--truth-root")
    sw.add_argument("--online", action="store_true", help="also probe each URL (light ranged GET)")
    sw.add_argument("--timeout", type=float, default=15.0)
    sw.add_argument("--enforce", action="store_true", help="exit nonzero if anything is flagged")
    sw.add_argument("--out")
    sw.set_defaults(fn=cmd_sweep)

    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
