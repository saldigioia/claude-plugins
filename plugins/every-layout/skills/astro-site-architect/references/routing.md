# Routing Patterns — Deep Reference

Astro uses file-based routing. Every file in `src/pages/` becomes a route.

---

## Static Routes

```
src/pages/index.astro        → /
src/pages/about.astro        → /about
src/pages/blog/index.astro   → /blog
src/pages/contact.astro      → /contact
```

No configuration needed. The file system IS the router.

---

## Dynamic Routes

### Single Parameter

```astro
<!-- src/pages/blog/[slug].astro -->
---
import { getCollection, render } from 'astro:content';
import Article from '../../layouts/Article.astro';

export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map(post => ({
    params: { slug: post.id },
    props: { post },
  }));
}

const { post } = Astro.props;
const { Content } = await render(post);
---

<Article title={post.data.title}>
  <Content />
</Article>
```

### Multiple Parameters

```astro
<!-- src/pages/[year]/[slug].astro -->
---
export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map(post => ({
    params: {
      year: post.data.date.getFullYear().toString(),
      slug: post.id,
    },
    props: { post },
  }));
}
---
```

Generates: `/2024/my-post`, `/2025/another-post`, etc.

### Rest Parameters (Catch-All)

```astro
<!-- src/pages/archive/[...path].astro -->
---
export async function getStaticPaths() {
  return [
    { params: { path: 'music/albums' } },
    { params: { path: 'music/singles' } },
    { params: { path: 'video/films' } },
    { params: { path: undefined } },  // Matches /archive
  ];
}
---
```

Generates: `/archive`, `/archive/music/albums`, `/archive/music/singles`, `/archive/video/films`.

---

## Archive Site Routing Patterns

### Pattern 1: Date-Based Routes

```
/archive/2024/                   # All entries from 2024
/archive/2024/01/                # January 2024
/archive/2024/01/entry-title     # Specific entry
```

```astro
<!-- src/pages/archive/[year]/[month]/[slug].astro -->
---
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const entries = await getCollection('archive');
  return entries.map(entry => {
    const date = entry.data.date;
    return {
      params: {
        year: date.getFullYear().toString(),
        month: String(date.getMonth() + 1).padStart(2, '0'),
        slug: entry.id,
      },
      props: { entry },
    };
  });
}
---
```

### Pattern 2: Collection-Based Routes

```
/music/                          # All music
/music/albums/                   # Albums index
/music/albums/album-title        # Specific album
/music/singles/                  # Singles index
```

```astro
<!-- src/pages/music/[type]/index.astro -->
---
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const works = await getCollection('works');
  const types = [...new Set(works.map(w => w.data.type))];

  return types.map(type => ({
    params: { type },
    props: {
      works: works.filter(w => w.data.type === type),
      type,
    },
  }));
}
---
```

### Pattern 3: Tag-Based Routes

```
/tags/                           # All tags
/tags/production                 # Entries tagged "production"
```

```astro
<!-- src/pages/tags/[tag].astro -->
---
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const posts = await getCollection('blog');
  const tags = [...new Set(posts.flatMap(p => p.data.tags))];

  return tags.map(tag => ({
    params: { tag },
    props: {
      posts: posts.filter(p => p.data.tags.includes(tag)),
      tag,
    },
  }));
}
---
```

### Pattern 4: Paginated Routes

```
/blog/                           # Page 1
/blog/2                          # Page 2
/blog/3                          # Page 3
```

```astro
<!-- src/pages/blog/[...page].astro -->
---
import { getCollection } from 'astro:content';

export async function getStaticPaths({ paginate }) {
  const posts = (await getCollection('blog'))
    .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());

  return paginate(posts, { pageSize: 12 });
}

const { page } = Astro.props;
// page.data = entries for this page
// page.currentPage, page.lastPage
// page.url.prev, page.url.next
---
```

---

## API Endpoints

For server-side functionality (search, form handlers):

```typescript
// src/pages/api/search.ts
import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

export const GET: APIRoute = async ({ url }) => {
  const query = url.searchParams.get('q')?.toLowerCase() || '';
  const posts = await getCollection('blog');

  const results = posts.filter(post =>
    post.data.title.toLowerCase().includes(query)
  );

  return new Response(JSON.stringify(results.map(r => ({
    title: r.data.title,
    url: `/blog/${r.id}`,
  }))), {
    headers: { 'Content-Type': 'application/json' },
  });
};
```

**Note:** API endpoints require `output: 'server'` or `output: 'hybrid'` in `astro.config.mjs`, unless pre-rendered at build time.

---

## RSS Feeds

```typescript
// src/pages/rss.xml.ts
import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';

export async function GET(context) {
  const posts = await getCollection('blog');

  return rss({
    title: 'My Archive',
    description: 'An archival site',
    site: context.site,
    items: posts
      .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf())
      .map(post => ({
        title: post.data.title,
        pubDate: post.data.date,
        description: post.data.description,
        link: `/blog/${post.id}/`,
      })),
  });
}
```

---

## Trailing Slashes

Configure in `astro.config.mjs`:

```javascript
export default defineConfig({
  trailingSlash: 'always',   // /blog/ (recommended for static hosting)
  // trailingSlash: 'never', // /blog
  // trailingSlash: 'ignore' // both work (default)
});
```

---

## 404 Pages

```astro
<!-- src/pages/404.astro -->
---
import Base from '../layouts/Base.astro';
---

<Base title="Not Found">
  <div class="cover">
    <div class="principal">
      <div class="center">
        <div class="stack">
          <h1>404</h1>
          <p>This page doesn't exist.</p>
          <a href="/">Return home</a>
        </div>
      </div>
    </div>
  </div>
</Base>
```

---

## URL Design Principles for Archives

1. **Semantic, not technical.** `/music/albums/graduation` not `/content?type=album&id=47`.
2. **Permanent.** Design URLs that never need to change. Avoid database IDs in URLs.
3. **Hierarchical.** `/category/subcategory/item` enables navigation by URL truncation.
4. **Lowercase, hyphenated.** `/the-college-dropout` not `/The_College_Dropout`.
5. **No file extensions.** `/about` not `/about.html`. Astro handles this by default.
6. **Date paths for temporal content.** `/archive/2024/01/event-name` preserves chronology in the URL itself.
