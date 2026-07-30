# WAF and bot walls — which lever fits which wall

**Orthogonal to every host rule.** The single most expensive mistake here is reaching for TLS
impersonation against a wall that is not fingerprint-based. Diagnose first.

| Wall | Signature | Lever |
|---|---|---|
| **Cloudflare managed challenge** | `cf-mitigated: challenge`, 403 "Just a moment" interstitial | `curl_cffi --impersonate chrome` |
| **Akamai Bot Manager (impersonation-mismatch)** | 403 `text/html` **+ `server:` starts with `akamai`** | `curl_cffi` firefox — or just send an **honest** UA |
| **AWS WAF Captcha** | 202 challenge, `gokuProps` token | **Impersonation is NOT enough** — needs a JS-solved cookie. Route around via Wayback |
| **Vercel Attack Challenge** | `<title>Vercel Security Checkpoint</title>`, HTTP 429 | `curl_cffi --impersonate chrome` |
| **Reddit content gate** | ~190 KB "blocked" page on every content surface | **Network/IP-level — impersonation is useless.** Use the open side-surfaces ([[reddit]]) |
| **Scene7 IP restriction** | 403 `Client IP address forbidden.` | Needs an allowlisted IP. Not publicly retrievable ([[pacsun-sfcc-scene7]]) |

## The Akamai inversion — worth internalising

Some Akamai-fronted hosts run Bot Manager with an **impersonation-mismatch rule**: a request
claiming a browser UA while presenting **curl's TLS ClientHello** is 403'd. This is the **inverse**
of the usual spoof-a-browser trick, so a hardcoded fake-Chrome UA is exactly what trips it.

Verified on one host:

```
fake-Chrome UA over curl TLS          → 403 text/html
honest curl / wget / python-requests  → 200
browser headers added over curl TLS   → still 403   (it is JA3/JA4, not headers)
curl_cffi firefox impersonation       → 200
```

**Failure symptom:** every probe (HEAD and the GET fallback, both carrying the fake UA) returns 403
`text/html` → content-type unknown → priority 99 → every candidate dropped → "no valid media format
found", 0 downloaded. A HEAD→GET fallback cannot rescue it, because GET is also non-2xx and
correctly refuses to override.

**Detection rule:** final status == 403 **AND** `server:` starts with `akamai`. Note there is **no
`cf-mitigated` header** here — that is Cloudflare-only, which is why a Cloudflare-shaped bypass
never fires on this wall.

## Keep more than one impersonation profile

Profiles are not interchangeable. One marketplace bot-walls `chrome` with a 403 "Pardon Our
Interruption" and clears cleanly on **`safari17_0`**. See [[reseller-marketplaces]].

## The general shape

**Image CDNs are usually open even when the page is walled.** Etsy, Grailed, Depop, eBay, Fril,
Dotdash, and Sanity all wall the HTML while serving images to plain curl. So the pattern is:
fetch HTML with impersonation → extract URLs → download images normally. Don't pay impersonation
cost on the bulk transfer.

## When the wall is real, route around it

An archived snapshot often carries the structured data the live page hides. Wayback CDX wildcards
recovered PDPs with full JSON-LD (SKUs + origin image paths) from a host behind AWS WAF —
**old snapshots are gold when the live page is locked.** See [[hypebeast]].

## Related

[[cloudflare-polish]] is a *different* Cloudflare feature — an image-quality issue, not an access
wall. Both can be present at once.
