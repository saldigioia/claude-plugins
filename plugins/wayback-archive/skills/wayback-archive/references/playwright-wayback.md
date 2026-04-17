# Playwright + Wayback Machine: Network Interception Pattern

This is the last-resort extraction method. Use CommonCrawl WARCs first.

## Why Playwright Mostly Fails on Wayback

- `networkidle` never fires — dead CDN resources mean the page never "finishes" loading
- Wayback's replay framework renders as the top-level document — the archived page content loads inside it, but Playwright captures the wrapper
- ~80% of Shopify page captures are anti-bot (Akamai) walls, not product content
- SPA pages (React/Adidas-era) render empty shells — data was loaded via API calls

## When Playwright IS Useful

The one thing it does well is **network interception** — even when the rendered page shows the Wayback toolbar, the browser still makes background requests to load CDN resources. These requests reveal product image URLs.

## The Pattern

```python
import asyncio
from playwright.async_api import async_playwright

async def extract_with_interception(url, handle):
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        
        # Intercept CDN requests
        cdn_urls = []
        page.on("request", lambda req: cdn_urls.append(req.url)
                if 'cdn.shopify.com' in req.url and '/products/' in req.url
                else None)
        
        # Use domcontentloaded — NEVER networkidle
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=20000)
        except:
            pass  # Timeout is OK, we still check what loaded
        
        # Wait for Wayback replay JS to settle
        await page.wait_for_timeout(8000)
        
        content = await page.content()
        
        # Extract metadata from rendered page (may be empty)
        title = await page.evaluate(
            "document.querySelector('meta[property=\"og:title\"]')?.content || "
            "document.title || ''")
        price = await page.evaluate(
            "document.querySelector('meta[property=\"og:price:amount\"]')?.content || ''")
        
        # The intercepted CDN URLs are often the most valuable result
        # Clean them: strip Wayback prefix, strip size suffixes
        import re
        clean_urls = set()
        for u in cdn_urls:
            u = re.sub(r'https?://web\.archive\.org/web/\d+[a-z_]*/', '', u)
            u = re.sub(r'_(grande|large|medium|\d+x\d*)(\.[a-z]+)', r'\2', u)
            u = u.split('?')[0]
            if not u.startswith('http'):
                u = 'https://' + u
            clean_urls.add(u)
        
        await page.close()
        await browser.close()
        
        return {
            'handle': handle,
            'title': title,
            'price': price,
            'image_urls': sorted(clean_urls),
            'network_intercept_count': len(cdn_urls),
        }
```

## Key Details

- **Fresh page per product**: Create a new page for each URL so network interception doesn't bleed across products
- **8-second wait**: Wayback's replay JS needs time to fire and load archived resources
- **Timeout is OK**: `try/except` around `goto` — even if the page times out, network requests may have captured CDN URLs
- **Filter CDN URLs by handle**: The page may load images from OTHER products (collection views, related products). Filter to URLs whose filename contains parts of the current handle, or accept all if no match
- **Rate limit**: 1.5-2 second delay between page loads
