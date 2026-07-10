# typo-scope.sh — shared scanner for ELP_034 "Scoped Typographic Permissions".
#
# word-break / overflow-wrap (and its legacy alias word-wrap) / hyphens are
# content-tier grants: legal on the container that actually holds
# untrusted-length content, never on `body`, `html`, `:root`, the bare
# universal selector, or heading selectors. A global grant is a site-wide
# license that display type eventually cashes in as a mid-word fracture
# ("The Manufacturer / s We Trust" at 390px — the Window Classics field
# report that produced ELP_034).
#
# typo_scope_scan <css-file>
#   Prints one TAB-delimited record per flagged grant:
#     <line>\t<selector>\t<declaration>
#   and nothing when the file is clean. Line numbers refer to <css-file>
#   (callers scanning .html/.astro pass the line-preserving <style> extract).
#
# What is flagged — a word-break/word-wrap/overflow-wrap/hyphens declaration
# whose innermost rule has a selector whose SUBJECT compound (the rightmost
# compound — the elements that actually receive the declaration) is body,
# html, :root, *, or h1–h6:
#   body            → flagged      .prose          → legal
#   .card h3        → flagged      body .prose     → legal (subject: .prose)
#   *, * + *        → flagged      .stack > *      → legal (scoped universal)
#
# Whitelists (grants nothing, or grants it where doctrine already allows):
#   - declarations inside @media print or @page blocks (print URL-breaking,
#     see framework-implementations/references/vanilla.md)
#   - the values normal | keep-all | none | manual | unset | initial |
#     revert | revert-layer (resets and manual hyphenation are not grants)
#
# Documented approximations (gate-grade, brace-counting — same family as
# css-strict.sh's other scanners, not a CSS parser): selectors inside
# :is()/:where()/:not() arguments are not expanded; a declaration missing
# its terminating `;` immediately before a next rule may be misread. This
# is a tripwire for ELP_034, not a selector engine.
#
# Written for bash 3.2 and onetrueawk (macOS): no gensub, no strtonum,
# no {n} interval expressions.
#
# Sourced by:
#   bin/css-strict.sh      (hard gate — ELA_003, cites ELP_034)
#   bin/css-lint-hook.sh   (PostToolUse warning tier)

typo_scope_scan() {
  awk '
    function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }

    # Does one comma-part of a selector have a forbidden subject compound?
    function forbidden_subject(part,    s, n, toks, subj) {
      s = part
      while (gsub(/\([^()]*\)/, "", s) > 0) { }   # strip functional args
      gsub(/\[[^]]*\]/, "", s)                    # strip attribute blocks
      gsub(/[>+~]/, " ", s)                       # combinators become spaces
      s = trim(s)
      if (s == "") return 0
      gsub(/[[:space:]]+/, " ", s)
      n = split(s, toks, " ")
      subj = toks[n]
      if (subj ~ /^\*/) return 1                  # universal subject
      if (index(subj, ":root") > 0) return 1
      if (subj ~ /^(body|html)$/) return 1
      if (subj ~ /^(body|html)[.:#]/) return 1
      if (subj ~ /^h[1-6]$/) return 1
      if (subj ~ /^h[1-6][.:#]/) return 1
      return 0
    }

    # Report every flagged typographic grant in one declaration segment.
    function scan_decls(seg,    i, m, decls, decl, val, sel, d, parts, np, j) {
      if (depth <= 0) return
      if (print_until >= 0) return                # print-context whitelist
      sel = ""
      for (d = depth - 1; d >= 0; d--) if (sels[d] != "") { sel = sels[d]; break }
      if (sel == "") return
      m = split(seg, decls, ";")
      for (i = 1; i <= m; i++) {
        decl = trim(decls[i])
        if (decl == "") continue
        if (decl !~ /^(-webkit-|-moz-|-ms-)?(word-break|word-wrap|overflow-wrap|hyphens)[[:space:]]*:/) continue
        val = decl
        sub(/^[^:]*:/, "", val)
        gsub(/!important/, "", val)
        val = tolower(trim(val))
        if (val ~ /^(normal|keep-all|none|manual|unset|initial|revert|revert-layer)$/) continue
        np = split(sel, parts, ",")
        for (j = 1; j <= np; j++) {
          if (forbidden_subject(parts[j])) {
            printf "%d\t%s\t%s\n", NR, trim(parts[j]), decl
            break
          }
        }
      }
    }

    BEGIN { depth = 0; print_until = -1; pend = ""; in_comment = 0 }
    {
      line = $0
      # Strip /* ... */ comments, tracking multi-line comment state.
      out = ""
      while (1) {
        if (in_comment) {
          idx = index(line, "*/")
          if (idx == 0) { line = ""; break }
          line = substr(line, idx + 2); in_comment = 0
        } else {
          idx = index(line, "/*")
          if (idx == 0) { out = out line; break }
          out = out substr(line, 1, idx - 1)
          rest2 = substr(line, idx + 2)
          e = index(rest2, "*/")
          if (e == 0) { in_comment = 1; line = ""; break }
          line = substr(rest2, e + 2)
        }
      }
      rest = out

      while (1) {
        ob = index(rest, "{"); cb = index(rest, "}")
        if (ob > 0 && (cb == 0 || ob < cb)) {
          head = pend substr(rest, 1, ob - 1)
          pend = ""
          # Declarations may precede a nested opening — split at the last ;
          nsem = 0
          for (k = length(head); k >= 1; k--) if (substr(head, k, 1) == ";") { nsem = k; break }
          if (nsem > 0) { scan_decls(substr(head, 1, nsem)); head = substr(head, nsem + 1) }
          head = trim(head)
          if (head ~ /^@/) {
            sels[depth] = ""
            if (print_until < 0 && (head ~ /^@page/ || (head ~ /^@media/ && head ~ /print/))) print_until = depth
          } else {
            sels[depth] = head
          }
          depth++
          rest = substr(rest, ob + 1)
        } else if (cb > 0) {
          scan_decls(substr(rest, 1, cb - 1))
          depth--
          if (depth < 0) depth = 0
          if (print_until >= 0 && depth <= print_until) print_until = -1
          pend = ""
          rest = substr(rest, cb + 1)
        } else {
          if (depth > 0) scan_decls(rest)
          if (trim(rest) != "") pend = pend rest " "
          break
        }
      }
    }
  ' "$1" 2>/dev/null
}
