# Extraction Strategy

## The Two Rules That Matter Most

**Rule 1: Always query BOTH Wayback Machine AND CommonCrawl.**

They have independent crawl schedules and different coverage. In testing,
CommonCrawl yielded a **76% success rate** for HTML content while Wayback
HTML yielded only **2.4%**. CommonCrawl was the single best content source
for server-rendered pages.

**Rule 2: For HTML content, prefer CommonCrawl WARCs over Wayback HTML.**

Wayback serves HTML through a JavaScript replay framework. `curl` gets a
~3KB shell. Playwright renders the Wayback toolbar, not the archived page.
Even when Playwright works, ~80% of captures are anti-bot (Akamai) pages.

CommonCrawl WARCs contain the **raw HTTP response** — the exact bytes the
crawler received. No JavaScript wrapper, no replay framework, no anti-bot
redirect. Product data is directly in the HTML.

```bash
# CommonCrawl WARC fetch — raw content, no wrapper
curl -s -H "Range: bytes={offset}-{offset+length-1}" \
  "https://data.commoncrawl.org/{warc_file}" | gunzip
```

**Rate limit**: 1 request/second to `data.commoncrawl.org`.

The response contains HTTP headers + body. Parse the body as HTML. If `gunzip`
fails or the output lacks `<html`, the record is corrupt — skip it.

## Extraction Method Hierarchy

In order of preference:

1. **Existing local data** — Parse files you already have (API JSONs, HTML pages,
   CSV exports). This can recover dozens of products for free from existing local data.

2. **Wayback `id_` direct** — Try every URL directly first with the `id_` modifier
   and no proxy. Fastest and cheapest. Works well for structured endpoints
   (JSON/Atom/oEmbed) and for HTML when Wayback isn't rate-limiting your IP.

3. **CommonCrawl WARCs** — When direct fails for HTML pages, `fetch_archive.py`
   queries up to 4 crawl indices per URL (with domain-level negative caching — if
   a domain misses 3 times, CC is skipped entirely for that domain). Raw WARC
   records fetched via HTTP Range requests to S3. No proxy needed, no rate limiting.
   76% success rate in testing.

4. **Wayback `id_` via ISP proxy** — Final automated fallback. The proxy provides
   IP rotation (20 residential IPs across ports 8001-8020) to avoid Wayback's 60
   req/min rate limit and escalating IP blocks.

5. **Playwright with network interception** — Last resort. Use `domcontentloaded`
   (NOT `networkidle`), wait 8s, intercept network requests for CDN URLs. Accept
   most pages will fail. See [playwright-wayback.md](playwright-wayback.md).

## Triage by Era/Platform

| Handle type | Method | Why |
|------------|--------|-----|
| Server-rendered (Shopify-era) | CommonCrawl WARC first | Raw HTML has product data inline |
| SPA/API (Adidas/React) | API JSON via curl | HTML is empty app shell |
| Structured endpoints | curl with `id_` | .json/.atom/.oembed don't need JS |
| Anti-bot blocked | Skip, log | No workaround except HAR from human browsing |

**The 90% rule**: If an extraction method fails on >90% of its first batch,
the method is wrong for this era/platform. Stop and switch — don't retry.

## HAR-Based Recovery

When automation fails (anti-bot, CAPTCHA, rate limiting), fall back to a hybrid
approach: human browsing + automated extraction. Give the user Wayback URLs to
browse manually, then parse their HAR files for CDN URLs.

Workflow:
1. Generate list of Wayback URLs for user to browse manually
2. Parse HAR files: extract CDN URLs from request URLs and response bodies
3. Strip Wayback prefixes (`https://web.archive.org/web/\d+(im_|if_)?/`)
4. Match discovered URLs to products using handles/SKU codes
5. Merge new CDN URLs into existing `links/{slug}.txt`, deduplicating
6. Trigger re-download via downloader stage
