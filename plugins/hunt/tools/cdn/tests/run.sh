#!/usr/bin/env bash
# Offline unit tests for app.sh pure functions (no network).
#
# Works because app.sh guards its main block with
#   if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi
# so sourcing loads every function without running the pipeline.
#
# Run:  bash tests/run.sh
# Exit: 0 = all pass, 1 = at least one failure.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$here/../app.sh"
set +euo pipefail   # tests assert on return values; don't abort on first non-zero

pass=0 fail=0

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected: [$2]"
    echo "  actual:   [$3]"
  fi
}

# ── format / content-type helpers ───────────────────────────────────────────
check "fmt_priority tif"      "1"  "$(fmt_priority tif)"
check "fmt_priority png"      "2"  "$(fmt_priority png)"
check "fmt_priority jpg"      "3"  "$(fmt_priority jpg)"
check "fmt_priority webp"     "5"  "$(fmt_priority webp)"
check "fmt_priority mp4"      "10" "$(fmt_priority mp4)"
check "fmt_priority flac"     "20" "$(fmt_priority flac)"
check "fmt_priority unknown"  "99" "$(fmt_priority unknown)"

check "ct_to_fmt png"   "png"  "$(ct_to_fmt image/png)"
check "ct_to_fmt jpeg"  "jpg"  "$(ct_to_fmt image/jpeg)"
check "ct_to_fmt tiff"  "tif"  "$(ct_to_fmt image/tiff)"
check "ct_to_fmt webp"  "webp" "$(ct_to_fmt image/webp)"
check "ct_to_fmt mp4"   "mp4"  "$(ct_to_fmt video/mp4)"
check "ct_to_fmt flac"  "flac" "$(ct_to_fmt audio/flac)"

# ── URL param helpers ───────────────────────────────────────────────────────
check "append_param no-query"   "http://x.com/a.jpg?fm=png"      "$(append_param 'http://x.com/a.jpg' fm png)"
check "append_param with-query" "http://x.com/a.jpg?q=1&fm=png"  "$(append_param 'http://x.com/a.jpg?q=1' fm png)"

check "strip_url_params some"   "http://x.com/a.jpg?fm=png"  "$(strip_url_params 'http://x.com/a.jpg?w=1&h=2&fm=png' w h)"
check "strip_url_params none"   "http://x.com/a.jpg"         "$(strip_url_params 'http://x.com/a.jpg' w)"
check "strip_url_params last"   "http://x.com/a.jpg"         "$(strip_url_params 'http://x.com/a.jpg?w=1' w)"

# ── basename derivation ─────────────────────────────────────────────────────
check "basename plain"          "photo"  "$(basename_from_url 'http://x.com/path/photo.JPG?x=1')"
check "basename mzstatic-spec"  "cc"     "$(basename_from_url 'https://is1-ssl.mzstatic.com/image/thumb/Music/aa/bb/cc/10000x10000.png')"
# every progressive_redirect URL ends in the same literal `file.mp4` (usually
# percent-encoded with a rendition suffix) — stem on id + rendition instead
check "basename vimeo-progressive" "vimeo_1144962023_720p" \
  "$(basename_from_url 'https://player.vimeo.com/progressive_redirect/playback/1144962023/rendition/720p/file.mp4%20%28720p%29.mp4?loc=external&signature=abc')"
check "basename vimeo-progressive download-path" "vimeo_385365963_1080p" \
  "$(basename_from_url 'https://player.vimeo.com/progressive_redirect/download/385365963/rendition/1080p/file.mp4?loc=external')"

# ── Akamai impolicy resolvers (NBC / FWRD / Revolve) ────────────────────────
check "nbc impolicy" \
  "https://img.nbc.com/files/2020/01/foo.png?impolicy=original" \
  "$(cdn_resolve_nbc 'https://img.nbc.com/files/2020/01/foo.png?w=300&h=200')"
check "nbc non-match" "" "$(cdn_resolve_nbc 'https://other.com/x.png')"

check "fwrd impolicy" \
  "https://is4.fwrdassets.com/images/p/fw/z/YEF3-WK1_V1.jpg?impolicy=original" \
  "$(cdn_resolve_fwrd 'https://is4.fwrdassets.com/images/p/fw/z/YEF3-WK1_V1.jpg')"
check "fwrd non-match" "" "$(cdn_resolve_fwrd 'https://is4.fwrdassets.com/css/site.css')"

check "revolve folder→z + impolicy" \
  "https://is2.revolveassets.com/images/p4/n/z/YEER-UO4W_V1.jpg?impolicy=original" \
  "$(cdn_resolve_revolve 'https://is2.revolveassets.com/images/p4/n/c/YEER-UO4W_V1.jpg?w=100')"

# ── GOAT (strip transform/v1, width-prefix, sub-size folder → original) ─────
check "goat transform/v1" \
  "https://image.goat.com/attachments/x/original/foo.jpg" \
  "$(cdn_resolve_goat 'https://image.goat.com/transform/v1/attachments/x/original/foo.jpg?action=crop&width=750')"
check "goat width-prefix" \
  "https://image.goat.com/attachments/x/original/foo.jpg" \
  "$(cdn_resolve_goat 'https://image.goat.com/750/attachments/x/original/foo.jpg')"
check "goat medium→original" \
  "https://image.goat.com/attachments/x/original/foo.jpg" \
  "$(cdn_resolve_goat 'https://image.goat.com/attachments/x/medium/foo.jpg')"

# ── Arc XP resizer (imbypass=true → byte-exact original master) ─────────────
check "arc resizer bare → imbypass" \
  "https://www.tampabay.com/resizer/v2/DDPVYSZPDNDDFOZPOWNIRMAZCM.JPG?auth=TOK&imbypass=true" \
  "$(cdn_resolve_arc_resizer 'https://www.tampabay.com/resizer/v2/DDPVYSZPDNDDFOZPOWNIRMAZCM.JPG?auth=TOK')"
check "arc resizer dimensioned thumb → imbypass overrides crop" \
  "https://www.tampabay.com/resizer/v2/X.JPG?auth=TOK&height=90&width=160&smart=true&imbypass=true" \
  "$(cdn_resolve_arc_resizer 'https://www.tampabay.com/resizer/v2/X.JPG?auth=TOK&height=90&width=160&smart=true')"
check "arc resizer without auth skipped" "" \
  "$(cdn_resolve_arc_resizer 'https://www.tampabay.com/resizer/v2/X.JPG' 2>/dev/null || true)"
check "arc non-resizer URL skipped" "" \
  "$(cdn_resolve_arc_resizer 'https://www.tampabay.com/photos/foo.JPG?auth=TOK' 2>/dev/null || true)"

# ── PMC / Jetpack Photon (strip all params → bare upload master) ─────────────
check "pmc lead crop+resize → bare master" \
  "https://www.rollingstone.com/wp-content/uploads/2026/06/Nasseri-RS-Friedland-Final-1.jpg" \
  "$(cdn_resolve_pmc 'https://www.rollingstone.com/wp-content/uploads/2026/06/Nasseri-RS-Friedland-Final-1.jpg?crop=155px,359px,2205px,1239px&resize=1600,900')"
check "pmc ?w= sized → bare master" \
  "https://variety.com/wp-content/uploads/2026/06/cover.jpg" \
  "$(cdn_resolve_pmc 'https://variety.com/wp-content/uploads/2026/06/cover.jpg?w=788')"
check "pmc already-bare URL skipped (no-op)" "" \
  "$(cdn_resolve_pmc 'https://www.rollingstone.com/wp-content/uploads/2026/06/Nasseri-RS-Friedland-Final-2.jpg' 2>/dev/null || true)"
check "pmc non-pmc host skipped" "" \
  "$(cdn_resolve_pmc 'https://example.com/wp-content/uploads/2026/06/x.jpg?w=100' 2>/dev/null || true)"
check "pmc non-image path skipped" "" \
  "$(cdn_resolve_pmc 'https://wwd.com/wp-content/uploads/2026/06/doc.pdf?w=100' 2>/dev/null || true)"
check "wants_original_accept rollingstone upload → true" "yes" \
  "$(wants_original_accept 'https://www.rollingstone.com/wp-content/uploads/2026/06/x.jpg' && echo yes || echo no)"
check "wants_original_accept plain host → false" "no" \
  "$(wants_original_accept 'https://example.com/a.jpg' && echo yes || echo no)"

# ── mzstatic resizer (→ 10000x10000.png lossless) ───────────────────────────
check "mzstatic resizer spec" \
  "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/aa/bb/cc/id/source/10000x10000.png" \
  "$(cdn_resolve_mzstatic 'https://is1-ssl.mzstatic.com/image/thumb/Music/v4/aa/bb/cc/id/source/1200x1200bb.jpg')"

# ── Substack (substackcdn fetch proxy → bare S3 master, no f_auto downscale) ─
check "substack fetch → bare tif master" \
  "https://substack-post-media.s3.amazonaws.com/public/images/08c9ae79-fb4c-4446-ab86-b93e9666c668.tif" \
  "$(cdn_resolve_substack 'https://substackcdn.com/image/fetch/$s_!PCf4!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F08c9ae79-fb4c-4446-ab86-b93e9666c668.tif')"
check "substack fetch with w_ cap → bare jpeg master" \
  "https://substack-post-media.s3.amazonaws.com/public/images/3fd8bd82-ae06-46cb-a2a1-88a8dc076b39_1806x1300.jpeg" \
  "$(cdn_resolve_substack 'https://substackcdn.com/image/fetch/$s_!NNmD!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F3fd8bd82-ae06-46cb-a2a1-88a8dc076b39_1806x1300.jpeg')"
check "substack non-fetch URL skipped" "" \
  "$(cdn_resolve_substack 'https://substack-post-media.s3.amazonaws.com/public/images/foo.tif' 2>/dev/null || true)"
check "substack non-substack host skipped" "" \
  "$(cdn_resolve_substack 'https://other.com/image/fetch/x/https%3A%2F%2Fy.com%2Fz.jpg' 2>/dev/null || true)"

# ── Playboy WP (re-hosted Substack upload → full-res S3 master) ─────────────
check "playboy full webp → S3 jpeg master" \
  "https://substack-post-media.s3.amazonaws.com/public/images/a24534de-5f5f-4992-8e1d-5b99cc979492_3552x5327.jpeg" \
  "$(cdn_resolve_playboy 'https://www.playboy.com/wp-content/uploads/2026/05/a24534de-5f5f-4992-8e1d-5b99cc979492_3552x5327.webp')"
check "playboy resize-suffix stripped → master" \
  "https://substack-post-media.s3.amazonaws.com/public/images/a75df1bb-8873-4cfd-a197-415a35fdfb98_3565x5330.jpeg" \
  "$(cdn_resolve_playboy 'https://www.playboy.com/wp-content/uploads/2026/05/a75df1bb-8873-4cfd-a197-415a35fdfb98_3565x5330-1370x2048.webp')"
check "playboy dedup -N suffix stripped → master" \
  "https://substack-post-media.s3.amazonaws.com/public/images/b128f99e-26cb-4786-9d36-3dc80fe135a3_3529x5300.jpeg" \
  "$(cdn_resolve_playboy 'https://www.playboy.com/wp-content/uploads/2026/05/b128f99e-26cb-4786-9d36-3dc80fe135a3_3529x5300-1.webp')"
check "playboy non-UUID asset skipped (theme/product img)" "" \
  "$(cdn_resolve_playboy 'https://www.playboy.com/wp-content/uploads/2026/05/bunny-logo-300x200.webp' 2>/dev/null || true)"
check "playboy non-playboy host skipped" "" \
  "$(cdn_resolve_playboy 'https://example.com/wp-content/uploads/2026/05/a24534de-5f5f-4992-8e1d-5b99cc979492_3552x5327.webp' 2>/dev/null || true)"

# ── Reddit (preview.redd.it signed resizer → i.redd.it stored master) ───────
check "reddit slugged preview → master" \
  "https://i.redd.it/djhfxqlyq1ah1.jpeg" \
  "$(cdn_resolve_reddit_preview 'https://preview.redd.it/itap-of-a-woman-enjoying-a-view-of-the-tetons-portrait-v0-djhfxqlyq1ah1.jpeg?width=1080&crop=smart&auto=webp&s=29d6fe2cf2c1ea6e9f69f7211110f5e1d2c3217f')"
check "reddit bare preview → master" \
  "https://i.redd.it/25in54i6y8ah1.jpeg" \
  "$(cdn_resolve_reddit_preview 'https://preview.redd.it/25in54i6y8ah1.jpeg?width=3024&format=pjpg&auto=webp&s=deadbeef')"
check "reddit gallery-item preview → master" \
  "https://i.redd.it/c4oo3lqmz4ah1.jpg" \
  "$(cdn_resolve_reddit_preview 'https://preview.redd.it/are-these-jordans-worth-anything-v0-c4oo3lqmz4ah1.jpg?width=640&crop=smart&auto=webp&s=abc123')"
check "reddit award/subpath asset skipped" "" \
  "$(cdn_resolve_reddit_preview 'https://preview.redd.it/award_images/t5_q0gj4/gold_512.png?width=16&s=x' 2>/dev/null || true)"
check "reddit external-preview skipped (opaque proxy key)" "" \
  "$(cdn_resolve_reddit_preview 'https://external-preview.redd.it/abcDEF123456.jpg?auto=webp&s=x' 2>/dev/null || true)"
check "reddit non-image ext skipped" "" \
  "$(cdn_resolve_reddit_preview 'https://preview.redd.it/some-clip-v0-abcdef123456.mp4?s=x' 2>/dev/null || true)"
check "reddit non-reddit host skipped" "" \
  "$(cdn_resolve_reddit_preview 'https://i.redd.it/djhfxqlyq1ah1.jpeg' 2>/dev/null || true)"

check "reddit post id from permalink" "1uigi5y" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/r/Sneakers/comments/1uigi5y/are_these_jordans_worth_anything/')"
check "reddit post id from id-only comments" "1uigi5y" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/comments/1uigi5y')"
check "reddit post id from gallery url" "1uigi5y" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/gallery/1uigi5y')"
check "reddit post id from shortlink" "1uigi5y" \
  "$(reddit_post_id_from_url 'https://redd.it/1uigi5y')"
check "reddit post id from user-profile post" "1abc234" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/user/someone/comments/1abc234/my_post/')"
check "reddit subreddit listing rejected" "" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/r/Sneakers/' 2>/dev/null || true)"
check "reddit share link rejected offline (needs redirect)" "" \
  "$(reddit_post_id_from_url 'https://www.reddit.com/r/Sneakers/s/AbCdEfGh12' 2>/dev/null || true)"

# ── Discogs (i.discogs.com signed imgproxy) — pure helpers only; the resolver
#    itself is network-bound (api.discogs.com), verified e2e ─────────────────
dg_full='https://i.discogs.com/CawpqRLEi8AArgqKEaWf8M-zmY7wDEBztESrmBKxZo4/rs:fit/g:sm/q:90/h:600/w:595/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTY2ODIx/NjItMTQyNDUzNjc2/MC04OTgyLmpwZWc.jpeg'
dg_thumb='https://i.discogs.com/CYQS17Ec6pmp8iE270D5PHZMz2xAk_Vw2nQgEoaAxmM/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9SLTY2ODIx/NjItMTQyNDUzNjc2/MC04OTgyLmpwZWc.jpeg'
check "discogs payload joined from full uri" \
  "czM6Ly9kaXNjb2dzLWRhdGFiYXNlLWltYWdlcy9SLTY2ODIxNjItMTQyNDUzNjc2MC04OTgyLmpwZWc" \
  "$(discogs_b64_payload "$dg_full")"
check "discogs payload identical for uri150 thumb (match key)" \
  "$(discogs_b64_payload "$dg_full")" \
  "$(discogs_b64_payload "$dg_thumb")"
check "discogs source file decoded (unpadded base64url)" \
  "R-6682162-1424536760-8982.jpeg" \
  "$(discogs_source_file "$dg_full")"
check "discogs basename uses decoded source stem" \
  "R-6682162-1424536760-8982" \
  "$(basename_from_url "$dg_full")"
check "discogs payload reject wrong host" "" \
  "$(discogs_b64_payload 'https://i.imgur.com/abc.jpg' 2>/dev/null || true)"
check "discogs source reject non-database-images payload" "" \
  "$(discogs_source_file 'https://i.discogs.com/sig/rs:fit/aHR0cHM6Ly9leGFt/cGxlLmNvbS9hLmpwZw.jpeg' 2>/dev/null || true)"
check "discogs resolver reject wrong host (offline path)" "" \
  "$(cdn_resolve_discogs 'https://i.imgur.com/abc.jpg' 2>/dev/null || true)"
check "discogs resolver reject undecodable payload (offline path)" "" \
  "$(cdn_resolve_discogs 'https://i.discogs.com/sig/rs:fit/not-valid-b64-!!/x.jpeg' 2>/dev/null || true)"

# ── hdnux (Hearst DAM rendition → rawImage.jpg stored master) ───────────────
check "hdnux webp rendition → rawImage master" \
  "https://s.hdnux.com/photos/01/66/60/54/31132466/5/rawImage.jpg" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/photos/01/66/60/54/31132466/5/ratio3x4_960.webp')"
check "hdnux jpg rendition → rawImage master" \
  "https://s.hdnux.com/photos/01/52/75/03/28037353/3/rawImage.jpg" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/photos/01/52/75/03/28037353/3/ratio1x1_160.jpg')"
check "hdnux square_small → rawImage master" \
  "https://s.hdnux.com/photos/01/66/60/54/31132463/5/rawImage.jpg" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/photos/01/66/60/54/31132463/5/square_small.jpg')"
check "hdnux rawImage with params → stripped" \
  "https://s.hdnux.com/photos/01/66/60/54/31132466/5/rawImage.jpg" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/photos/01/66/60/54/31132466/5/rawImage.jpg?w=9999')"
check "hdnux already-master skipped" "" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/photos/01/66/60/54/31132466/5/rawImage.jpg' 2>/dev/null || true)"
check "hdnux non-photos path skipped" "" \
  "$(cdn_resolve_hdnux 'https://s.hdnux.com/other/01/66/60/54/31132466/5/ratio3x4_960.webp' 2>/dev/null || true)"
check "hdnux non-hdnux host skipped" "" \
  "$(cdn_resolve_hdnux 'https://example.com/photos/01/66/60/54/31132466/5/ratio3x4_960.webp' 2>/dev/null || true)"

# ── futurecdn (Future PLC "kodiak" rendition/crop grammars → bare stored master)
check "futurecdn -W-Q.png.webp → bare master" \
  "https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc-2000-80.png.webp')"
check "futurecdn -W-Q.png → bare master" \
  "https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc-2000-80.png')"
check "futurecdn -W-Q.jpg.webp → bare master" \
  "https://cdn.mos.cms.futurecdn.net/z6S9qXJFDMqqj3XEknsQiP.jpg" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/z6S9qXJFDMqqj3XEknsQiP-1280-80.jpg.webp')"
check "futurecdn thumbnail rung → bare master" \
  "https://cdn.mos.cms.futurecdn.net/vLnVW9vUexvqmpNpj2DiHb.jpg" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/vLnVW9vUexvqmpNpj2DiHb-140-80.jpg')"
check "futurecdn /v2 crop transform → uncropped master" \
  "https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/v2/t:0,l:437,cw:1125,ch:1125,q:80,w:1125/gWvRYCQwqDrbLJmL6kLwRc.png')"
check "futurecdn /v2 crop + .webp → uncropped master" \
  "https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/v2/t:0,l:250,cw:1500,ch:1125,q:80,w:1500/gWvRYCQwqDrbLJmL6kLwRc.png.webp')"
check "futurecdn /flexiimages chrome → bare master" \
  "https://cdn.mos.cms.futurecdn.net/flexiimages/mednnv697g1760357120.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/flexiimages/mednnv697g1760357120-280-100.png.webp')"
check "futurecdn ignored query params stripped" \
  "https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png?width=4000&quality=100')"
check "futurecdn http scheme preserved" \
  "http://cdn.mos.cms.futurecdn.net/25heGV68LEDh6tt2iUy3y8.jpg" \
  "$(cdn_resolve_futurecdn 'http://cdn.mos.cms.futurecdn.net/25heGV68LEDh6tt2iUy3y8-800-450.jpg')"
check "futurecdn gif rendition → bare master" \
  "https://cdn.mos.cms.futurecdn.net/aBcDeF123.gif" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/aBcDeF123-600-80.gif')"
check "futurecdn already-bare master skipped" "" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/gWvRYCQwqDrbLJmL6kLwRc.png' 2>/dev/null || true)"
check "futurecdn bare svg chrome skipped" "" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net/flexiimages/p5lektiuwq1683127037.svg' 2>/dev/null || true)"
check "futurecdn look-alike host skipped" "" \
  "$(cdn_resolve_futurecdn 'https://cdn.mos.cms.futurecdn.net.evil.com/x-100-80.png' 2>/dev/null || true)"
check "futurecdn non-futurecdn host skipped" "" \
  "$(cdn_resolve_futurecdn 'https://example.com/gWvRYCQwqDrbLJmL6kLwRc-2000-80.png' 2>/dev/null || true)"
check "basename hdnux → photo-id stem" "hdnux_31132466" \
  "$(basename_from_url 'https://s.hdnux.com/photos/01/66/60/54/31132466/5/rawImage.jpg')"

# ── Facebook lookaside (transcode_extension → png lossless master) ──────────
check "fbsbx webp→png" \
  "https://lookaside.fbsbx.com/elementpath/media/?media_id=1008507011807962&version=1781821583&transcode_extension=png" \
  "$(fbsbx_png_url 'https://lookaside.fbsbx.com/elementpath/media/?media_id=1008507011807962&version=1781821583&transcode_extension=webp')"
check "fbsbx jpg→png" \
  "https://lookaside.fbsbx.com/elementpath/media/?media_id=123&version=9&transcode_extension=png" \
  "$(fbsbx_png_url 'https://lookaside.fbsbx.com/elementpath/media/?media_id=123&version=9&transcode_extension=jpg')"
check "fbsbx no-transcode (svg icon) skipped" "" \
  "$(fbsbx_png_url 'https://lookaside.fbsbx.com/elementpath/media/?media_id=123&version=9' || true)"
check "fbsbx non-match" "" \
  "$(fbsbx_png_url 'https://other.com/elementpath/media/?media_id=1&transcode_extension=webp' || true)"

# ── StockX (→ stockx.imgix.net unrestricted root, no params) ────────────────
check "stockx imgix root" \
  "https://stockx.imgix.net/images/Some-Shoe.jpg" \
  "$(cdn_resolve_stockx 'https://images.stockx.com/images/Some-Shoe.jpg?fit=fill&w=300')"

# ── SKIMS (skims.imgix.net + skims-sanity.imgix.net → bare lossy source) ─────
check "skims imgix strip params" \
  "https://skims.imgix.net/s/files/1/0259/5448/4284/files/PANTY_00020_SK_097_F9x300_FINAL.webp" \
  "$(cdn_resolve_skims 'https://skims.imgix.net/s/files/1/0259/5448/4284/files/PANTY_00020_SK_097_F9x300_FINAL.webp?v=1774284571&auto=format&q=70&w=1446')"
check "skims sanity strip params" \
  "https://skims-sanity.imgix.net/images/hfqi0zm0/production/b4753d-786x1128.webp" \
  "$(cdn_resolve_skims 'https://skims-sanity.imgix.net/images/hfqi0zm0/production/b4753d-786x1128.webp?auto=format&q=95&w=2619')"
check "skims no-op on bare (signal fallthrough)" \
  "" \
  "$(cdn_resolve_skims 'https://skims.imgix.net/s/files/1/0259/5448/4284/files/PANTY.webp' 2>/dev/null)"
check "skims rejects non-skims imgix" \
  "" \
  "$(cdn_resolve_skims 'https://stockx.imgix.net/images/Some-Shoe.jpg?w=300' 2>/dev/null)"
check "is_skims_imgix_url matches product host" \
  "yes" \
  "$(is_skims_imgix_url 'https://skims.imgix.net/s/files/x.webp' && echo yes || echo no)"
check "is_skims_imgix_url rejects shopify origin" \
  "no" \
  "$(is_skims_imgix_url 'https://cdn.shopify.com/s/files/x.webp' && echo yes || echo no)"

# ── BDG / imgix.bustle.com (custom imgix host → ?q=100 hi-q master) ──────────
check "bustle imgix append q=100 (strip page params)" \
  "https://imgix.bustle.com/uploads/image/2024/12/16/588d545e/oshiro_ga_-22_edit_final.jpg?q=100" \
  "$(cdn_resolve_imgix_bustle 'https://imgix.bustle.com/uploads/image/2024/12/16/588d545e/oshiro_ga_-22_edit_final.jpg?w=777&h=971&fit=crop&crop=faces&dpr=2')"
check "bustle imgix append q=100 (bare input)" \
  "https://imgix.bustle.com/uploads/image/2025/3/18/09d88997/nylon_gracie-abrams_cover_social.jpg?q=100" \
  "$(cdn_resolve_imgix_bustle 'https://imgix.bustle.com/uploads/image/2025/3/18/09d88997/nylon_gracie-abrams_cover_social.jpg')"
check "bustle imgix rejects .imgix.net host" \
  "" \
  "$(cdn_resolve_imgix_bustle 'https://stockx.imgix.net/images/Some-Shoe.jpg?w=300' 2>/dev/null)"
check "bustle imgix rejects non-bustle host" \
  "" \
  "$(cdn_resolve_imgix_bustle 'https://cdn.sanity.io/images/x/y/z-100x100.jpg' 2>/dev/null)"

# ── Cloudinary bare-origin guard (pure/no-network reject paths only) ─────────
# cloudinary_bare_master must bail out BEFORE any curl on inputs that can't be the
# appended-.png re-wrap case, so the offline harness never hits the wire. The
# byte-exact-match positive path is network-bound and verified via the e2e run.
check "cloudinary_bare_master rejects non-cloudinary host" "no" \
  "$(cloudinary_bare_master 'https://example.com/a.png' >/dev/null && echo yes || echo no)"
check "cloudinary_bare_master rejects cloudinary non-.png (already-extensioned/bare)" "no" \
  "$(cloudinary_bare_master 'https://res.cloudinary.com/allyou/image/upload/v1/3/39541/images/12366315/S1_0144_1_rwnpxs' >/dev/null && echo yes || echo no)"
check "cloudinary_bare_master rejects cloudinary .jpg public id" "no" \
  "$(cloudinary_bare_master 'https://res.cloudinary.com/allyou/image/upload/v1/x/photo.jpg' >/dev/null && echo yes || echo no)"

# ── Akamai Bot Manager 403 detection (curl_cffi retry trigger) ──────────────
# Akamai properties like press.warnerrecords.com 403 our spoofed-browser UA over
# curl's TLS fingerprint; is_akamai_bot_blocked flags the raw HEAD so head_info
# retries via curl_cffi's real browser TLS. Pure string function over the raw
# response headers — verified offline against realistic (CRLF) header blocks.
_akamai_403=$'HTTP/2 403 \r\nserver: AkamaiGHost\r\nmime-version: 1.0\r\ncontent-type: text/html\r\ncontent-length: 490\r\n\r\n'
_akamai_200=$'HTTP/2 200 \r\nserver: AkamaiGHost\r\ncontent-type: image/jpeg\r\ncontent-length: 1535398\r\n\r\n'
_cf_403=$'HTTP/2 403 \r\nserver: cloudflare\r\ncontent-type: text/html\r\n\r\n'
_nginx_403=$'HTTP/2 403 \r\nserver: nginx\r\ncontent-type: text/html\r\n\r\n'
_akamai_404=$'HTTP/2 404 \r\nserver: AkamaiGHost\r\ncontent-type: text/html\r\n\r\n'

check "akamai 403 bot-block detected" "yes" \
  "$(is_akamai_bot_blocked "$_akamai_403" && echo yes || echo no)"
check "akamai 200 is not a block" "no" \
  "$(is_akamai_bot_blocked "$_akamai_200" && echo yes || echo no)"
check "cloudflare 403 is not an akamai block" "no" \
  "$(is_akamai_bot_blocked "$_cf_403" && echo yes || echo no)"
check "nginx 403 is not an akamai block" "no" \
  "$(is_akamai_bot_blocked "$_nginx_403" && echo yes || echo no)"
check "akamai 404 is not the bot-403 block" "no" \
  "$(is_akamai_bot_blocked "$_akamai_404" && echo yes || echo no)"

# ── self-hosted / direct media page discovery ───────────────────────────────
# Pages that play a plain progressive file (production-company and portfolio
# sites) carry no Mux/Vimeo ID, so before direct_media_from_html they fell
# through to the image pipeline and died on "no valid media format found".
# Tier 1 (<video>/<source> src) must win over a CMS JSON island so a page whose
# JSON also lists a short autoplay teaser yields the full film alone.
_div_html='<div><video class="Player" src="https://datamanagement.gosimian.com/assets/videos/TOR_Charli-XCX_SS26.mp4" playsinline autoplay muted></video></div><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"project":{"film":"https://datamanagement.gosimian.com/assets/videos/TOR_Charli-XCX_SS26.mp4","preview":"https://datamanagement.gosimian.com/assets/videos/TOR_Preview-Charli-XCX_SS26.mp4"}}}}</script>'

check "direct media: <video src> wins over JSON teaser" \
  "https://datamanagement.gosimian.com/assets/videos/TOR_Charli-XCX_SS26.mp4" \
  "$(direct_media_from_html 'https://www.division.global/videos/charli-xcx-ss26' "$_div_html")"

check "direct media: og:video fallback when no player element" \
  "https://cdn.example.com/films/reel.mp4" \
  "$(direct_media_from_html 'https://example.com/work/reel' \
     '<meta property="og:video" content="https://cdn.example.com/films/reel.mp4">')"

check "direct media: JSON island fallback when no player/meta" \
  "https://cdn.example.com/a.mp4" \
  "$(direct_media_from_html 'https://example.com/x' '<script>{"film":"https://cdn.example.com/a.mp4"}</script>')"

check "direct media: absolute-path src resolved against host" \
  "https://example.com/assets/clip.webm" \
  "$(direct_media_from_html 'https://example.com/work/thing' \
     '<video src="/assets/clip.webm"></video>')"

check "direct media: protocol-relative src takes page scheme" \
  "https://cdn.example.com/clip.mov" \
  "$(direct_media_from_html 'https://example.com/w' '<source src="//cdn.example.com/clip.mov">')"

check "direct media: multiple <source> entries deduped, order kept" \
  "https://example.com/a.mp4
https://example.com/b.webm" \
  "$(direct_media_from_html 'https://example.com/p' \
     '<video><source src="https://example.com/a.mp4"><source src="https://example.com/b.webm"><source src="https://example.com/a.mp4"></video>')"

check "direct media: HTML entity in query unescaped" \
  "https://example.com/v.mp4?a=1&b=2" \
  "$(direct_media_from_html 'https://example.com/p' \
     '<video src="https://example.com/v.mp4?a=1&amp;b=2"></video>')"

check "direct media: poster image is not a media hit" "no" \
  "$(direct_media_from_html 'https://example.com/p' \
     '<video poster="https://example.com/p.jpg" src="https://example.com/p.jpg"></video>' \
     >/dev/null && echo yes || echo no)"

check "direct media: page with no media returns nothing" "no" \
  "$(direct_media_from_html 'https://example.com/p' '<p>hello</p>' >/dev/null && echo yes || echo no)"

# ── Squarespace native video discovery ──────────────────────────────────────
# The player block carries only an HTML-escaped JSON config whose alexandriaUrl
# is a {variant} template — no <video src>, no iframe, no media-extension URL —
# so every URL-shaped extractor missed it (marzmiller.com). The parser rebuilds
# <base>/playlist.m3u8 from the base, collapsing template/thumbnail/playlist
# forms onto one URL.
_sqsp_vid_html='<div class="sqs-native-video" data-config-video="{&quot;systemDataSourceType&quot;:&quot;mp4&quot;,&quot;alexandriaUrl&quot;:&quot;https://video.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/0060372e-eda5-429f-b06f-ee53ecfc6839/{variant}&quot;,&quot;systemDataVariants&quot;:&quot;1998:1080,666:360&quot;}"></div>'

check "sqsp video: {variant} template → playlist.m3u8" \
  "https://video.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/0060372e-eda5-429f-b06f-ee53ecfc6839/playlist.m3u8" \
  "$(squarespace_video_urls_from_html "$_sqsp_vid_html")"

check "sqsp video: template + thumbnail collapse to one playlist" \
  "https://video.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/0060372e-eda5-429f-b06f-ee53ecfc6839/playlist.m3u8" \
  "$(squarespace_video_urls_from_html "${_sqsp_vid_html}<img src=\"https://video.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/0060372e-eda5-429f-b06f-ee53ecfc6839/thumbnail\">")"

check "sqsp video: two distinct assets kept, order preserved" \
  "https://video.squarespace-cdn.com/content/v1/aaaa/1111-2222/playlist.m3u8
https://video.squarespace-cdn.com/content/v1/aaaa/3333-4444/playlist.m3u8" \
  "$(squarespace_video_urls_from_html '<a href="https://video.squarespace-cdn.com/content/v1/aaaa/1111-2222/{variant}"></a><a href="https://video.squarespace-cdn.com/content/v1/aaaa/3333-4444/thumbnail"></a>')"

check "sqsp video: images.squarespace-cdn.com is not a video hit" "no" \
  "$(squarespace_video_urls_from_html '<img src="https://images.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/00c81e13/favicon.ico">' >/dev/null && echo yes || echo no)"

check "sqsp video: page with no native video returns nothing" "no" \
  "$(squarespace_video_urls_from_html '<p>hello</p>' >/dev/null && echo yes || echo no)"

# ── YouTube embed discovery ─────────────────────────────────────────────────
# Squarespace stores the Embedly iframe HTML-escaped inside a data-block-json
# attribute, so the video id only appears URL-encoded
# (youtube.com%2Fembed%2F<id>, watch%3Fv%3D<id>) — the form that previously
# matched no extractor and died in the image pipeline (andrewdonoho.com).
_sqs_html='<div data-block-json="&quot;html&quot;:&quot;&lt;iframe src=&quot;//cdn.embedly.com/widgets/media.html?src=https%3A%2F%2Fwww.youtube.com%2Fembed%2F5fbZTnZDvPA%3Ffeature%3Doembed&amp;amp;url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D5fbZTnZDvPA&amp;amp;image=https%3A%2F%2Fi.ytimg.com%2Fvi%2F5fbZTnZDvPA%2Fhqdefault.jpg&quot;&gt;&lt;/iframe&gt;&quot;"></div>'

check "youtube: squarespace/embedly url-encoded block" "5fbZTnZDvPA" \
  "$(youtube_ids_from_html "$_sqs_html")"

check "youtube: plain iframe embed" "dQw4w9WgXcQ" \
  "$(youtube_ids_from_html '<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ?rel=0"></iframe>')"

check "youtube: nocookie host" "dQw4w9WgXcQ" \
  "$(youtube_ids_from_html '<iframe src="https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"></iframe>')"

check "youtube: watch link" "dQw4w9WgXcQ" \
  "$(youtube_ids_from_html '<a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">watch</a>')"

check "youtube: youtu.be shortlink" "dQw4w9WgXcQ" \
  "$(youtube_ids_from_html '<a href="https://youtu.be/dQw4w9WgXcQ">w</a>')"

check "youtube: same id in many forms deduped" "5fbZTnZDvPA" \
  "$(youtube_ids_from_html '<iframe src="https://www.youtube.com/embed/5fbZTnZDvPA"></iframe><a href="https://www.youtube.com/watch?v=5fbZTnZDvPA">x</a><img src="https://i.ytimg.com/vi/5fbZTnZDvPA/hqdefault.jpg">')"

check "youtube: two distinct ids, order kept" "5fbZTnZDvPA
dQw4w9WgXcQ" \
  "$(youtube_ids_from_html '<iframe src="https://www.youtube.com/embed/5fbZTnZDvPA"></iframe><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>')"

check "youtube: videoseries playlist embed excluded" "no" \
  "$(youtube_ids_from_html '<iframe src="https://www.youtube.com/embed/videoseries?list=PLx8h4"></iframe>' >/dev/null && echo yes || echo no)"

check "youtube: page with no youtube returns nothing" "no" \
  "$(youtube_ids_from_html '<p>hello</p>' >/dev/null && echo yes || echo no)"

# ── Vimeo JSON-island discovery (vimeo_scrape_embed_ids Strategy 4) ─────────
# Sanity/Next.js router preloads embed api.vimeo.com video objects as escaped
# JSON; the stable marker is "uri":"/videos/<id>/...". A preload can carry the
# site's whole catalog (larkcreative.tv: 209 videos), so multi-id islands are
# disambiguated by matching a URL-derived slug against a "slug" field and
# taking the byte-offset-nearest video id; no slug match → decline.
_island_esc='x \"client\":\"Charli XCX\",\"content\":{\"id\":\"1204909087\",\"uri\":\"/videos/1204909087/pictures/2173361454\"},\"slug\":\"wink-wink\" y'

check "vimeo island: single id, escaped json" "1204909087" \
  "$(vimeo_ids_from_json_island "$_island_esc" 'https://www.larkcreative.tv/work?play=wink-wink')"

check "vimeo island: single id, plain json" "9876543" \
  "$(vimeo_ids_from_json_island '{"uri":"/videos/9876543"}' 'https://x.tv/page')"

check "vimeo island: single id, escaped slashes" "1204909087" \
  "$(vimeo_ids_from_json_island 'a \"uri\":\"\/videos\/1204909087\/pictures\/1\" b' 'https://x.tv/p')"

_island_multi='{"items":[{"client":"A","content":{"id":"1111111","uri":"/videos/1111111/pictures/1"},"slug":"first-vid"},{"client":"B","content":{"id":"2222222","uri":"/videos/2222222/pictures/2"},"slug":"second-vid"}]}'

check "vimeo island: multi-id, query-param slug picks item" "2222222" \
  "$(vimeo_ids_from_json_island "$_island_multi" 'https://x.tv/work?play=second-vid')"

check "vimeo island: multi-id, first slug picks item" "1111111" \
  "$(vimeo_ids_from_json_island "$_island_multi" 'https://x.tv/work?play=first-vid')"

check "vimeo island: multi-id, fragment slug picks item" "2222222" \
  "$(vimeo_ids_from_json_island "$_island_multi" 'https://x.tv/work#second-vid')"

check "vimeo island: multi-id, no slug match declines" "no" \
  "$(vimeo_ids_from_json_island "$_island_multi" 'https://x.tv/work' >/dev/null && echo yes || echo no)"

check "vimeo island: no api uris declines" "no" \
  "$(vimeo_ids_from_json_island '<p>hello</p>' 'https://x.tv/work?play=first-vid' >/dev/null && echo yes || echo no)"

# ── Vimeo bare-id discovery (vimeo_scrape_embed_ids Strategy 2) ──────────────
# Webflow binds a "Vimeo ID" CMS field to a custom attribute holding the bare
# numeric id (data-vimeo="<id>") and templates the same id into the schema.org
# VideoObject as "contentUrl":"<id>" — neither is URL-shaped, so every
# URL-matching strategy missed them and the page died in the image pipeline
# (bodeyco.com).
_webflow_html='<div data-vimeo="1144962023" class="video"><video><source data-src="" type="video/mp4"></video></div>'
_jsonld_html='<script type="application/ld+json">{"@type":"VideoObject","name":"V1","contentUrl":"1144962023"},{"@type":"VideoObject","name":"V2","contentUrl":""}</script><a href="https://vimeo.com/bodeyco">vimeo</a>'

check "vimeo bare-id: webflow data-vimeo attribute" "1144962023" \
  "$(vimeo_ids_from_data_attrs "$_webflow_html")"

check "vimeo bare-id: data-vimeo-id attribute" "385365963" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo-id="385365963">')"

check "vimeo bare-id: legacy data-video-id preserved" "12345" \
  "$(vimeo_ids_from_data_attrs '<div data-video-id="12345">')"

check "vimeo bare-id: json-ld contentUrl, empty siblings ignored" "1144962023" \
  "$(vimeo_ids_from_data_attrs "$_jsonld_html")"

check "vimeo bare-id: json-ld contentUrl declines when page never says vimeo" "no" \
  "$(vimeo_ids_from_data_attrs '{"@type":"VideoObject","contentUrl":"1144962023"}' >/dev/null && echo yes || echo no)"

check "vimeo bare-id: sub-6-digit contentUrl not an id" "no" \
  "$(vimeo_ids_from_data_attrs 'vimeo {"contentUrl":"123"}' >/dev/null && echo yes || echo no)"

check "vimeo bare-id: url-valued data-vimeo attr not mistaken for an id" "no" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo="https://vimeo.com/385365963">' >/dev/null && echo yes || echo no)"

check "vimeo bare-id: page with no signal declines" "no" \
  "$(vimeo_ids_from_data_attrs '<p>hello</p>' >/dev/null && echo yes || echo no)"

# ── input URL normalization ─────────────────────────────────────────────────
# A URL copied out of devtools arrives scheme-less; curl tolerates it but aria2c
# dies with "Unrecognized URI or unsupported protocol" only AFTER the probe
# pipeline has picked a winner.
check "normalize: scheme-less host gets https" \
  "https://player.vimeo.com/progressive_redirect/playback/1/rendition/720p/file.mp4?a=b" \
  "$(normalize_url 'player.vimeo.com/progressive_redirect/playback/1/rendition/720p/file.mp4?a=b')"

check "normalize: existing scheme untouched" "https://x.com/a" \
  "$(normalize_url 'https://x.com/a')"

check "normalize: http scheme untouched" "http://x.com/a" \
  "$(normalize_url 'http://x.com/a')"

check "normalize: surrounding whitespace trimmed" "https://x.com/a" \
  "$(normalize_url '   https://x.com/a   ')"

check "normalize: trailing CR stripped" "https://x.com/a" \
  "$(normalize_url "$(printf 'https://x.com/a\r')")"

check "normalize: protocol-relative gets https" "https://cdn.example.com/a.jpg" \
  "$(normalize_url '//cdn.example.com/a.jpg')"

check "normalize: bare host with port" "https://example.com:8080/a" \
  "$(normalize_url 'example.com:8080/a')"

check "normalize: IPv4 host gets https" "https://192.168.1.10/cam/a.jpg" \
  "$(normalize_url '192.168.1.10/cam/a.jpg')"

check "normalize: localhost with port gets https" "https://localhost:8080/a.mp4" \
  "$(normalize_url 'localhost:8080/a.mp4')"

check "normalize: userinfo@host gets https" "https://user:pw@host.com/a" \
  "$(normalize_url 'user:pw@host.com/a')"

check "normalize: underscore label gets https" "https://cdn_1.example.com/a.jpg" \
  "$(normalize_url 'cdn_1.example.com/a.jpg')"

check "normalize: a scheme inside the QUERY is not the url's scheme" "https://x.com/a?next=https://y" \
  "$(normalize_url 'x.com/a?next=https://y')"

check "normalize: non-host-shaped input left alone" "notaurl" \
  "$(normalize_url 'notaurl')"

check "normalize: whitespace-only declines" "no" \
  "$(normalize_url '   ' >/dev/null && echo yes || echo no)"

# read_urls: an argv value pasted with a trailing newline used to yield a second,
# empty URL that ran the whole pipeline and was tallied as a phantom failure.
check "read_urls: trailing newline yields one url, not two" \
  "https://player.vimeo.com/x.mp4" \
  "$(printf 'player.vimeo.com/x.mp4\n\n' | read_urls)"

check "read_urls: comments and blanks skipped, scheme supplied" \
  "https://a.com/1
https://b.com/2" \
  "$(printf '# note\n\na.com/1\n\nhttps://b.com/2\n' | read_urls)"

# a URL copied out of the registry (the lever itself) must not need a page
check "sqsp video: a bare CDN url on argv rebuilds its playlist" \
  "https://video.squarespace-cdn.com/content/v1/aaaa/1111-2222/playlist.m3u8" \
  "$(squarespace_video_urls_from_html 'https://video.squarespace-cdn.com/content/v1/aaaa/1111-2222/{variant}')"

check "basename sqsp-video (asset id, not playlist/thumbnail/{variant})" \
  "sqsp_0060372e-eda5-429f-b06f-ee53ecfc6839" \
  "$(basename_from_url 'https://video.squarespace-cdn.com/content/v1/5334c422e4b097e4d9d69f2f/0060372e-eda5-429f-b06f-ee53ecfc6839/playlist.m3u8')"

# data-vimeo-id is the platform's own attribute: any id length (pre-2008 ids
# are 5 digits) — the generic data-*vimeo* form still needs 6+ to self-attribute
check "vimeo bare-id: short data-vimeo-id (early id) still found" "54321" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo-id="54321">')"

check "vimeo bare-id: short value on a generic data-*vimeo* attr declines" "no" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo="54321">' >/dev/null && echo yes || echo no)"

check "vimeo bare-id: a digit in the attribute NAME is not an id" "1144962023" \
  "$(vimeo_ids_from_data_attrs '<div data-w3-vimeo="1144962023">')"

# collect_urls is where the phantom second URL actually lived (argv branch);
# read_urls always skipped blank lines, so only this exercises the fix
check "collect_urls: argv value with a trailing newline is ONE url" "1" \
  "$(POSITIONAL=($'https://x.com/a\n'); collect_urls | wc -l | tr -d ' ')"

check "collect_urls: argv value is normalized like a file line" "https://x.com/a" \
  "$(POSITIONAL=('  x.com/a  '); collect_urls)"

# a 6-digit NON-id attribute (start offset, duration) must not become an id:
# the short-circuit returned both, and handle_vimeo ran on the stranger's id
check "vimeo bare-id: data-vimeo-start beside the real id yields only the id" "385365963" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo-start="123456" data-vimeo-id="385365963">')"

check "vimeo bare-id: data-vimeo-duration alone is not an id" "no" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo-duration="600000">' >/dev/null && echo yes || echo no)"

check "vimeo bare-id: data-vimeo-video-id carrier still found" "385365963" \
  "$(vimeo_ids_from_data_attrs '<div data-vimeo-video-id="385365963">')"

# a mistyped list-file name must not become https://urls.txt
check "collect_urls: a missing list-file name yields no url" "" \
  "$(POSITIONAL=('urls.txt'); collect_urls 2>/dev/null)"

check "collect_urls: …and says so on stderr" "yes" \
  "$(POSITIONAL=('urls.txt'); collect_urls 2>&1 >/dev/null | grep -q 'no such file: urls.txt' && echo yes || echo no)"

check "collect_urls: a dotted host with a path is still a url" "https://example.com/a.json" \
  "$(POSITIONAL=('example.com/a.json'); collect_urls)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo " tests: $((pass + fail))  pass: $pass  fail: $fail"
echo "────────────────────────────────────────"
[[ $fail -eq 0 ]]
