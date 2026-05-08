"""Plan-markdown rendering.

Composes the human-readable markdown plan that plan.py prints to stderr
for operator review. The "What this means" block translates engineering
decisions into plain-prose consequences before the rationale block; the
reference-bundle section appears only when Cmd 19 opt-in is active.
"""
from __future__ import annotations


def what_this_means(plan: dict, group: dict) -> list[str]:
    """Two-to-four plain-prose bullets summarizing the group's output for
    a non-expert mixer. Leads with consequences; engineer detail follows
    underneath in render_plan_markdown.
    """
    fmt = group["format"]
    bullets: list[str] = []

    # Format consequence
    fmt_label = f"{fmt['format'].upper()}"
    rate_khz = fmt["rate"] / 1000.0
    depth_label = f"{fmt['depth']}-bit" if fmt["depth"] else "lossy"
    if fmt.get("lie"):
        bullets.append(
            f"This output is **DEGENERATE** — the manifest forced "
            f"{fmt_label} {rate_khz:.1f} kHz / {depth_label} even though the "
            f"source can't honestly carry it. The filename will carry "
            f"`.degenerate` to make this unmistakable."
        )
    elif "Lossy input present" in fmt.get("rationale", ""):
        bullets.append(
            f"This output is **{fmt_label} {rate_khz:.1f} kHz / {depth_label}** "
            f"because at least one of your stems is a lossy file. Once any link "
            f"in the chain is lossy, claiming more precision in the deliverable "
            f"is a fidelity lie."
        )
    elif "FLAC stable encoder caps at 24-bit" in fmt.get("rationale", ""):
        bullets.append(
            f"This output is **{fmt_label} {rate_khz:.1f} kHz / 24-bit** even "
            f"though your source is 32-bit, because portable FLAC caps at 24. "
            f"The lost precision lives below any real-signal noise floor — "
            f"24-bit FLAC is mathematically lossless for any signal worth "
            f"keeping. For a genuine 32-bit deliverable, request format=wav "
            f"or aiff in the manifest."
        )
    else:
        bullets.append(
            f"This output is **{fmt_label} {rate_khz:.1f} kHz / {depth_label}**, "
            f"matching what the source supports."
        )

    # Pan-law consequence (only if mono stems exist)
    if group.get("has_mono_stems"):
        pl = group.get("pan_law_db", 0.0)
        if pl == 0.0:
            bullets.append(
                "Pan law is **0 dB** — mono stems centered will be **+3 dB hotter** "
                "than the same stems through any DAW. This is a deliberate "
                "manifest choice; if it wasn't, set `output.pan_law: -3.0` "
                "in the manifest to match Logic / Cubase."
            )
        elif group.get("pan_law_was_default"):
            bullets.append(
                f"Pan law is **{pl:+.1f} dB** (default — the Logic / Cubase "
                f"convention). Pro Tools sessions use **-2.5 dB** by default; "
                f"if you're trying to null against a Pro Tools bounce, set "
                f"`output.pan_law: -2.5` in the manifest."
            )
        else:
            bullets.append(
                f"Pan law is **{pl:+.1f} dB** (declared in the manifest). "
                f"Mono stems centered apply a coefficient of "
                f"{group.get('pan_law_coefficient', 1.0):.4f} per channel."
            )

    # Pre-attenuation consequence
    pre = group.get("pre_attenuation_db", 0.0)
    if pre != 0.0:
        bullets.append(
            f"Pre-summing attenuation: **{pre:+.2f} dB** applied uniformly to "
            f"every stem to land the sum at ~-3 dBTP. Relative balance is "
            f"preserved; nothing post-sum (no normalization, no limiting)."
        )

    # Per-stem manifest gain hint
    gains = group.get("per_stem_gains") or {}
    nonzero = {fn: g for fn, g in gains.items() if g != 0.0}
    if nonzero:
        gain_summary = ", ".join(f"`{fn}` {g:+.1f} dB" for fn, g in nonzero.items())
        bullets.append(
            f"Manifest gain trims applied: {gain_summary}. These are pre-sum "
            f"per-stem volumes, intended for fixing balance bugs upstream — "
            f"not creative mixing decisions."
        )

    return bullets


def render_plan_markdown(plan: dict) -> str:
    out = []
    out.append("# stems-to-mixdown / Plan\n")
    out.append(f"_Generated {plan['generated_at']}_\n")
    out.append(f"**Project:** `{plan['project']}`")
    out.append(f"**Source:** `{plan['directory']}`")
    out.append(f"**Output dir:** `{plan['output_directory']}`\n")
    if plan.get("any_lie"):
        out.append("> **⚠️ DEGENERATE MODE** — at least one group's output exceeds source honesty.")
        out.append("> Outputs marked with `.degenerate` suffix. See per-group rationale.\n")
    for g in plan["groups"]:
        out.append(f"## Group: `{g['name']}`")
        out.append(f"**Output:** `{g['output_path']}`")
        out.append(f"**Format:** {g['format']['format']} / {g['format']['rate']} Hz / "
                   f"{g['format']['depth'] or 'lossy'}-bit / {g['format']['channels']}ch")
        # Plain-English block leads. Engineer detail underneath.
        bullets = what_this_means(plan, g)
        if bullets:
            out.append("\n**What this means:**\n")
            for b in bullets:
                out.append(f"- {b}")
            out.append("")
        out.append(f"**Rationale:** {g['format']['rationale']}\n")
        out.append("**Stems:**\n")
        for sf in g["stem_files"]:
            out.append(f"- `{sf}`")
        out.append("")
        out.append(f"**Measured mix peak (pre-atten):** "
                   f"{g['measured_peak_dbtp']:.2f} dBTP" if g['measured_peak_dbtp'] is not None
                   else "**Measured mix peak:** unavailable")
        out.append(f"**Pre-attenuation applied:** {g['pre_attenuation_db']:+.2f} dB")
        out.append(f"_{g['pre_attenuation_rationale']}_\n")
        if g["format"]["dither_required"]:
            out.append("**Dither:** triangular high-pass at final encode (16-bit target).")
        if g["format"]["lie"]:
            out.append("**⚠️ This group's output is DEGENERATE — exceeds source ceiling.**")
        out.append("")

    # Reference bundle (Cmd 19) — appears only when the operator opted in.
    rb = plan.get("reference_bundle")
    if rb is not None:
        out.append("## Reference bundle\n")
        out.append(f"**Bundle dir:** `{rb['directory']}`")
        out.append(f"**Format:** {rb['format']['format']} / {rb['format']['rate']} Hz / "
                   f"{rb['format']['depth']}-bit / {rb['format']['channels']}ch")
        out.append("\n**What this means:**\n")
        out.append("- Three perfectly synchronized files for A/B listening and null-test verification.")
        out.append("- The master is the witness, not the source (Cmd 19). Pass 5 will null-test "
                   "`(instrumental + acapella)` against the master and report the residual dBTP.")
        out.append(f"- Master: `{rb['master_reference']['path']}` "
                   f"(SHA `{rb['master_reference']['sha256'][:16]}…`).")
        out.append("")
        out.append("**Members:**\n")
        for m in rb["members"]:
            mark = " (re-encoded into bundle format)" if m.get("needs_reencode") else ""
            out.append(f"- `{m['role']}` → `{m['output_path']}`{mark}")
        out.append("")
        out.append(f"**Rationale:** {rb['rationale']}")
        out.append("")
    return "\n".join(out)
