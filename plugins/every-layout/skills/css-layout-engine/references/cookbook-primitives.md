# Cookbook — Primitives

> **Scope — this file:** *variations* on the core primitives — alternative parameterisations, common configurations, and worked examples for each ID.
> For the canonical primitive specification (parameters, `applies_when`, `fails_when`, verification tests) see `primitives.md`. For multi-primitive compositions and end-to-end page patterns, see `cookbook-recipes.md`.

---

# Box Cookbook

## Basic Usage

The Box applies padding and an optional border to create a distinct visual container.

```html
<div class="box">
  <p>Content inside a padded container</p>
</div>
```

## Recipes

### Recipe 1: Callout Banner

```html
<div class="box" data-invert style="--padding: var(--s2)">
  <div class="stack" style="--space: var(--s-1)">
    <h2>Important Notice</h2>
    <p>This service will be unavailable this weekend for maintenance.</p>
  </div>
</div>
```

**Why this works:**
- `data-invert` swaps foreground and background for high contrast
- Larger padding (`--s2`) gives the callout visual weight
- Inner Stack controls spacing between heading and body

### Recipe 2: Pricing Card

```html
<div class="box" style="--border-width: 2px; --padding: var(--s2)">
  <div class="stack" data-split-after="3">
    <h3>Pro Plan</h3>
    <p class="price">$29/mo</p>
    <ul class="stack" style="--space: var(--s-1)">
      <li>Unlimited projects</li>
      <li>Priority support</li>
      <li>Advanced analytics</li>
    </ul>
    <a href="#" class="button">Get Started</a>
  </div>
</div>
```

**Why this works:**
- Box provides consistent padding and a visible border
- `data-split-after="3"` pushes the CTA button to the bottom
- Nested Stack with tight spacing keeps the feature list compact

### Recipe 3: Sidebar Widget

```html
<aside class="box" data-invert style="--padding: var(--s1)">
  <div class="stack" style="--space: var(--s0)">
    <h4>Quick Links</h4>
    <nav>
      <ul class="stack" style="--space: var(--s-1)">
        <li><a href="#">Documentation</a></li>
        <li><a href="#">API Reference</a></li>
        <li><a href="#">Community</a></li>
      </ul>
    </nav>
  </div>
</aside>
```

**Why this works:**
- Inverted Box draws attention in a sidebar layout
- Semantic `<aside>` and `<nav>` support accessibility
- Stack maintains consistent list spacing

## Common Combinations

### Box + Stack (Content Section)
```html
<div class="box">
  <div class="stack">
    <h2>Section Title</h2>
    <p>Section content...</p>
  </div>
</div>
```

### Box + Cluster (Tag List)
```html
<div class="box" style="--padding: var(--s-1)">
  <div class="cluster" style="--space: var(--s-2)">
    <span>HTML</span>
    <span>CSS</span>
    <span>JavaScript</span>
  </div>
</div>
```

### Box + Center (Contained Alert)
```html
<div class="center" style="--measure: 40ch">
  <div class="box" data-invert>
    <p>Centered alert message</p>
  </div>
</div>
```

## Verification Checklist

- [ ] Padding is consistent on all sides
- [ ] `data-invert` swaps foreground and background correctly
- [ ] Child text color inherits from Box
- [ ] Border width responds to `--border-width` custom property

---

# Center Cookbook

## Basic Usage

The Center constrains content width and centers it horizontally with gutters.

```html
<div class="center">
  <p>This content is centered with a max-width of 60ch.</p>
</div>
```

## Recipes

### Recipe 1: Article Page

```html
<main class="center" style="--measure: 65ch; --gutter: var(--s2)">
  <article class="stack" style="--space: var(--s1)">
    <h1>Article Title</h1>
    <p>First paragraph of the article...</p>
    <p>Second paragraph continues here...</p>
  </article>
</main>
```

**Why this works:**
- `--measure: 65ch` keeps lines at an optimal reading length
- `--gutter` provides safe padding on narrow viewports
- `box-sizing: content-box` ensures gutters don't eat into the measure

### Recipe 2: Intrinsic Centering (Narrow Content)

```html
<div class="center" data-intrinsic>
  <img src="logo.svg" alt="Logo" style="max-inline-size: 200px">
  <p>Tagline text centered under the logo</p>
</div>
```

**Why this works:**
- `data-intrinsic` uses flexbox to center children by their natural width
- Image and text shrink-wrap to their content, then center as a group
- No need to set explicit widths on the children

### Recipe 3: Hero Text Block

```html
<div class="center" data-text style="--measure: 40ch">
  <div class="stack" style="--space: var(--s0)">
    <h1>Welcome to Our Platform</h1>
    <p>A short introductory paragraph that sets the scene.</p>
    <div class="cluster" style="--justify: center">
      <a href="#">Get Started</a>
      <a href="#">Learn More</a>
    </div>
  </div>
</div>
```

**Why this works:**
- `data-text` aligns the text content to center
- Narrower `--measure` creates a focused reading column
- Cluster with `--justify: center` aligns the CTA buttons

## Common Combinations

### Center + Stack (Standard Page)
```html
<div class="center">
  <div class="stack">
    <h1>Page Title</h1>
    <p>Content...</p>
  </div>
</div>
```

### Center + Sidebar (Documentation)
```html
<div class="center" style="--measure: 90ch">
  <div class="with-sidebar">
    <nav><!-- sidebar nav --></nav>
    <main class="stack"><!-- content --></main>
  </div>
</div>
```

### Center + Grid (Portfolio)
```html
<div class="center">
  <div class="grid" style="--min: 20rem">
    <div><!-- project 1 --></div>
    <div><!-- project 2 --></div>
    <div><!-- project 3 --></div>
  </div>
</div>
```

## Verification Checklist

- [ ] Content does not exceed `--measure` width
- [ ] Gutters provide padding on narrow viewports
- [ ] `data-intrinsic` centers children by their content width
- [ ] `data-text` applies `text-align: center`
- [ ] `box-sizing: content-box` prevents gutters from reducing measure

---

# Cluster Cookbook

## Basic Usage

The Cluster distributes items horizontally with wrapping and configurable alignment.

```html
<div class="cluster">
  <span>Tag One</span>
  <span>Tag Two</span>
  <span>Tag Three</span>
</div>
```

## Recipes

### Recipe 1: Navigation Bar

```html
<nav class="cluster" style="--justify: space-between; --align: center">
  <a href="/" class="logo">Site Name</a>
  <div class="cluster" style="--space: var(--s1)">
    <a href="/about">About</a>
    <a href="/work">Work</a>
    <a href="/contact">Contact</a>
  </div>
</nav>
```

**Why this works:**
- Outer Cluster pushes logo and nav links apart with `space-between`
- Inner Cluster groups nav links with their own spacing
- Items wrap naturally on narrow viewports — no breakpoints needed

### Recipe 2: Tag Cloud

```html
<ul class="cluster" style="--space: var(--s-2)">
  <li><a href="#" class="box" style="--padding: var(--s-2)">CSS</a></li>
  <li><a href="#" class="box" style="--padding: var(--s-2)">Layout</a></li>
  <li><a href="#" class="box" style="--padding: var(--s-2)">Flexbox</a></li>
  <li><a href="#" class="box" style="--padding: var(--s-2)">Grid</a></li>
  <li><a href="#" class="box" style="--padding: var(--s-2)">Typography</a></li>
</ul>
```

**Why this works:**
- Tight spacing (`--s-2`) creates a dense, visually cohesive cluster
- Each tag is a Box for consistent padding and borders
- Natural wrapping handles any number of tags

### Recipe 3: Form Actions Row

```html
<div class="cluster" style="--justify: flex-end; --space: var(--s0)">
  <button type="button">Cancel</button>
  <button type="submit">Save Changes</button>
</div>
```

**Why this works:**
- `--justify: flex-end` aligns buttons to the inline end
- Buttons wrap if space is constrained
- Gap handles spacing — no margin hacks

## Common Combinations

### Cluster + Box (Toolbar)
```html
<div class="box" style="--padding: var(--s-1)">
  <div class="cluster" style="--space: var(--s-1)">
    <button>Bold</button>
    <button>Italic</button>
    <button>Underline</button>
  </div>
</div>
```

### Cluster + Stack (Metadata Line)
```html
<article class="stack">
  <h2>Article Title</h2>
  <div class="cluster" style="--space: var(--s-1)">
    <span>Jan 15, 2024</span>
    <span>·</span>
    <span>5 min read</span>
  </div>
  <p>Article body...</p>
</article>
```

### Cluster + Center (Centered Actions)
```html
<div class="center" data-intrinsic>
  <div class="cluster" style="--justify: center">
    <a href="#">Primary Action</a>
    <a href="#">Secondary Action</a>
  </div>
</div>
```

## Verification Checklist

- [ ] Items wrap to new lines when space runs out
- [ ] Gap is consistent between all items (no double spacing at wrap points)
- [ ] `--justify` controls horizontal distribution
- [ ] `--align` controls vertical alignment of items

---

# Container Cookbook

## Basic Usage

The Container establishes a container query context, allowing children to respond to the container's width instead of the viewport.

```html
<div class="container">
  <div class="child">
    <!-- This child can use @container queries -->
  </div>
</div>
```

## Recipes

### Recipe 1: Responsive Card (Container-Aware)

```html
<div class="container">
  <article class="card">
    <img src="hero.jpg" alt="Card image">
    <div class="stack" style="--space: var(--s-1)">
      <h3>Card Title</h3>
      <p>Description text that adapts to the card's width.</p>
    </div>
  </article>
</div>

<style>
  .card {
    display: grid;
    gap: var(--s1);
  }
  @container (min-width: 30rem) {
    .card {
      grid-template-columns: 1fr 2fr;
    }
  }
</style>
```

**Why this works:**
- Container provides `container-type: inline-size`
- The card switches from stacked to horizontal based on *its own width*
- Same card works in a sidebar, a grid cell, or a full-width layout

### Recipe 2: Named Container (Dashboard Widget)

```html
<section class="container" data-name style="--name: widget">
  <div class="stack">
    <h3>Monthly Revenue</h3>
    <div class="chart"><!-- chart content --></div>
    <div class="stat-row">
      <span>$45,230</span>
      <span>+12.5%</span>
    </div>
  </div>
</section>

<style>
  .stat-row {
    display: flex;
    flex-direction: column;
    gap: var(--s-2);
  }
  @container widget (min-width: 25rem) {
    .stat-row {
      flex-direction: row;
      justify-content: space-between;
    }
  }
</style>
```

**Why this works:**
- `data-name` with `--name: widget` creates a named container
- `@container widget` targets only this specific container
- Multiple widgets on a dashboard can have different query contexts
- Stats row adapts to the widget's width, not the viewport

### Recipe 3: Grid Items with Container Queries

```html
<div class="grid" style="--min: 18rem">
  <div class="container">
    <div class="feature-card">
      <h3>Feature A</h3>
      <p>Description of feature A with details.</p>
      <a href="#">Learn more</a>
    </div>
  </div>
  <div class="container">
    <div class="feature-card">
      <h3>Feature B</h3>
      <p>Description of feature B with details.</p>
      <a href="#">Learn more</a>
    </div>
  </div>
</div>

<style>
  .feature-card { padding: var(--s0); }
  .feature-card a { display: none; }
  @container (min-width: 20rem) {
    .feature-card { padding: var(--s2); }
    .feature-card a { display: inline; }
  }
</style>
```

**Why this works:**
- Each grid item is its own container context
- Cards adapt independently based on their column width
- "Learn more" link shows only when the card has enough space
- Padding adjusts based on available width

## Common Combinations

### Container + Grid (Adaptive Grid Items)
```html
<div class="grid" style="--min: 15rem">
  <div class="container"><!-- item 1 --></div>
  <div class="container"><!-- item 2 --></div>
  <div class="container"><!-- item 3 --></div>
</div>
```

### Container + Sidebar (Adaptive Panels)
```html
<div class="with-sidebar">
  <aside class="container">
    <!-- sidebar content adapts to sidebar width -->
  </aside>
  <main class="container">
    <!-- main content adapts to main width -->
  </main>
</div>
```

### Container + Switcher (Adaptive Columns)
```html
<div class="switcher">
  <div class="container"><!-- col 1 --></div>
  <div class="container"><!-- col 2 --></div>
</div>
```

## Verification Checklist

- [ ] Container establishes `container-type: inline-size`
- [ ] `@container` queries respond to the container's width, not the viewport
- [ ] Named containers (`data-name` + `--name`) scope queries correctly
- [ ] Container does not affect the visual appearance of its children
- [ ] Nested containers each create independent query contexts

---

# Cover Cookbook

## Basic Usage

The Cover vertically centers a principal element with optional header and footer, filling a minimum block size.

```html
<div class="cover">
  <header>Top content</header>
  <div data-centered>
    <h1>Centered content</h1>
  </div>
  <footer>Bottom content</footer>
</div>
```

## Recipes

### Recipe 1: Hero Section

```html
<div class="cover" style="--min-height: 100vh; --padding: var(--s2)">
  <header>
    <nav class="cluster" style="--justify: space-between">
      <a href="/">Logo</a>
      <div class="cluster">
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
      </div>
    </nav>
  </header>
  <div data-centered class="stack" style="--space: var(--s1)">
    <h1>Build Better Layouts</h1>
    <p>A compositional approach to CSS that just works.</p>
    <div class="cluster">
      <a href="#start">Get Started</a>
      <a href="#learn">Learn More</a>
    </div>
  </div>
  <footer>
    <p>Scroll to explore ↓</p>
  </footer>
</div>
```

**Why this works:**
- Cover fills the viewport (`100vh`) with the heading vertically centered
- Header nav stays at top, scroll hint stays at bottom
- `data-centered` element gets `margin-block: auto` to push into center

### Recipe 2: Login Card

```html
<main class="cover" style="--min-height: 100vh; --padding: var(--s2)">
  <div></div>
  <div data-centered>
    <div class="box center" style="--measure: 30ch; --padding: var(--s2)">
      <form class="stack">
        <h1>Sign In</h1>
        <label>Email <input type="email"></label>
        <label>Password <input type="password"></label>
        <button type="submit">Log In</button>
      </form>
    </div>
  </div>
  <footer>
    <p><a href="#">Forgot password?</a></p>
  </footer>
</main>
```

**Why this works:**
- Cover centers the login form vertically in the viewport
- Empty `<div>` as first child balances the footer
- Box + Center constrains the form to a comfortable width

### Recipe 3: Error Page (No Padding)

```html
<div class="cover" data-no-pad style="--min-height: 100vh">
  <div></div>
  <div data-centered class="center" data-text>
    <div class="stack">
      <h1>404</h1>
      <p>The page you're looking for doesn't exist.</p>
      <a href="/">Go Home</a>
    </div>
  </div>
  <footer class="box" style="--padding: var(--s0)">
    <p>Need help? <a href="/support">Contact support</a></p>
  </footer>
</div>
```

**Why this works:**
- `data-no-pad` removes Cover padding — the footer Box provides its own
- Centered 404 message dominates the page
- Footer sticks to bottom with its own contained padding

## Common Combinations

### Cover + Center (Landing Page)
```html
<div class="cover" style="--min-height: 100vh">
  <div></div>
  <div data-centered class="center">
    <div class="stack"><!-- content --></div>
  </div>
  <footer><!-- footer --></footer>
</div>
```

### Cover + Switcher (Split Hero)
```html
<div class="cover">
  <div></div>
  <div data-centered class="switcher">
    <div class="stack"><!-- text --></div>
    <div class="frame"><!-- image --></div>
  </div>
  <div></div>
</div>
```

### Cover + Stack (Full-Page Form)
```html
<div class="cover" style="--min-height: 100vh">
  <header>Step 1 of 3</header>
  <form data-centered class="stack">
    <!-- form fields -->
  </form>
  <footer class="cluster" style="--justify: space-between">
    <button>Back</button>
    <button>Next</button>
  </footer>
</div>
```

## Verification Checklist

- [ ] `data-centered` element is vertically centered
- [ ] Header stays at top, footer stays at bottom
- [ ] Cover fills at least `--min-height`
- [ ] `data-no-pad` removes all Cover padding
- [ ] First/last children without `data-centered` have no extra margin

---

# Frame Cookbook

## Basic Usage

The Frame constrains media to a specific aspect ratio, cropping as needed.

```html
<div class="frame">
  <img src="photo.jpg" alt="A landscape photo">
</div>
```

## Recipes

### Recipe 1: Video Embed (16:9)

```html
<div class="frame" style="--n: 16; --d: 9">
  <iframe
    src="https://www.youtube-nocookie.com/embed/VIDEO_ID"
    title="Video title"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
    allowfullscreen>
  </iframe>
</div>
```

**Why this works:**
- Default 16:9 ratio matches standard video content
- `object-fit: cover` on the iframe fills the frame completely
- No wrapper hacks — `aspect-ratio` handles the sizing natively

### Recipe 2: Square Avatar

```html
<div class="frame" style="--n: 1; --d: 1; max-inline-size: 5rem">
  <img src="avatar.jpg" alt="User profile photo" style="border-radius: 50%">
</div>
```

**Why this works:**
- `--n: 1; --d: 1` creates a 1:1 square
- `max-inline-size` constrains the avatar to a fixed size
- `border-radius: 50%` on the image creates a circular crop
- `object-fit: cover` ensures the face fills the circle

### Recipe 3: Cinema Letterbox (21:9)

```html
<div class="frame" style="--n: 21; --d: 9">
  <img src="panorama.jpg" alt="Wide panoramic landscape">
</div>
```

**Why this works:**
- Ultra-wide ratio creates a cinematic letterbox effect
- Image is cropped to fit, centered by default
- `--object-position` can shift the focal point if needed

## Common Combinations

### Frame + Grid (Gallery)
```html
<div class="grid" style="--min: 15rem">
  <div class="frame"><img src="1.jpg" alt="Photo 1"></div>
  <div class="frame"><img src="2.jpg" alt="Photo 2"></div>
  <div class="frame"><img src="3.jpg" alt="Photo 3"></div>
</div>
```

### Frame + Reel (Horizontal Gallery)
```html
<div class="reel" style="--item-width: 20rem">
  <div class="frame"><img src="slide-1.jpg" alt="Slide 1"></div>
  <div class="frame"><img src="slide-2.jpg" alt="Slide 2"></div>
  <div class="frame"><img src="slide-3.jpg" alt="Slide 3"></div>
</div>
```

### Frame + Sidebar (Article with Hero)
```html
<div class="with-sidebar" style="--side-width: 20rem">
  <div class="frame" style="--n: 3; --d: 4">
    <img src="hero.jpg" alt="Article hero">
  </div>
  <div class="stack">
    <h1>Article Title</h1>
    <p>Content...</p>
  </div>
</div>
```

## Verification Checklist

- [ ] Frame maintains aspect ratio at any container width
- [ ] `object-fit: cover` fills the frame without distortion
- [ ] `--object-position` shifts the focal point when set
- [ ] `img` and `video` children are sized to 100% of the frame
- [ ] Frame clips overflow content

---

# Grid Cookbook

## Basic Usage

The Grid creates a responsive grid that automatically adjusts column count based on available space, with no media queries.

```html
<div class="grid">
  <div>Item 1</div>
  <div>Item 2</div>
  <div>Item 3</div>
  <div>Item 4</div>
</div>
```

## Recipes

### Recipe 1: Card Grid

```html
<div class="grid" style="--min: 18rem; --space: var(--s2)">
  <article class="box stack">
    <h3>Card Title</h3>
    <p>Card description that explains the topic.</p>
    <a href="#">Read more →</a>
  </article>
  <article class="box stack">
    <h3>Another Card</h3>
    <p>Each card takes equal width.</p>
    <a href="#">Read more →</a>
  </article>
  <article class="box stack">
    <h3>Third Card</h3>
    <p>The grid wraps as needed.</p>
    <a href="#">Read more →</a>
  </article>
</div>
```

**Why this works:**
- `--min: 18rem` sets the minimum card width — columns form automatically
- `auto-fit` creates as many columns as will fit above the minimum
- `min(var(--min), 100%)` ensures single items span full width on narrow screens

### Recipe 2: Image Gallery

```html
<div class="grid" style="--min: 12rem; --space: var(--s-1)">
  <div class="frame">
    <img src="photo-1.jpg" alt="Photo 1">
  </div>
  <div class="frame">
    <img src="photo-2.jpg" alt="Photo 2">
  </div>
  <div class="frame">
    <img src="photo-3.jpg" alt="Photo 3">
  </div>
  <div class="frame">
    <img src="photo-4.jpg" alt="Photo 4">
  </div>
  <div class="frame">
    <img src="photo-5.jpg" alt="Photo 5">
  </div>
  <div class="frame">
    <img src="photo-6.jpg" alt="Photo 6">
  </div>
</div>
```

**Why this works:**
- Small minimum (`12rem`) creates a dense gallery grid
- Tight spacing (`--s-1`) keeps images close for visual cohesion
- Each Frame maintains consistent aspect ratios

### Recipe 3: Dashboard Stats

```html
<div class="grid" style="--min: 15rem; --space: var(--s1)">
  <div class="box" data-invert>
    <div class="stack" style="--space: var(--s-2)">
      <p>Total Users</p>
      <p><strong>12,345</strong></p>
    </div>
  </div>
  <div class="box" data-invert>
    <div class="stack" style="--space: var(--s-2)">
      <p>Revenue</p>
      <p><strong>$98,765</strong></p>
    </div>
  </div>
  <div class="box" data-invert>
    <div class="stack" style="--space: var(--s-2)">
      <p>Conversion</p>
      <p><strong>4.2%</strong></p>
    </div>
  </div>
  <div class="box" data-invert>
    <div class="stack" style="--space: var(--s-2)">
      <p>Active Now</p>
      <p><strong>573</strong></p>
    </div>
  </div>
</div>
```

**Why this works:**
- Stats arrange in 4, 3, 2, or 1 columns depending on space
- Inverted Boxes create visual distinction for KPI cards
- Stacks maintain clean vertical rhythm inside each stat

## Common Combinations

### Grid + Stack (Card with Content)
```html
<div class="grid">
  <div class="stack">
    <h3>Title</h3>
    <p>Content...</p>
  </div>
  <!-- more cards -->
</div>
```

### Grid + Center (Contained Grid)
```html
<div class="center" style="--measure: 80rem">
  <div class="grid" style="--min: 20rem">
    <!-- grid items -->
  </div>
</div>
```

### Grid + Frame (Media Grid)
```html
<div class="grid" style="--min: 15rem">
  <div class="frame"><img src="a.jpg" alt="A"></div>
  <div class="frame"><img src="b.jpg" alt="B"></div>
  <div class="frame"><img src="c.jpg" alt="C"></div>
</div>
```

## Verification Checklist

- [ ] Columns form automatically based on `--min` and available width
- [ ] Single item spans full width when container is narrow
- [ ] No media queries are used for column changes
- [ ] Gap is consistent in both axes
- [ ] Items stretch to equal height by default

---

# Icon Cookbook

## Basic Usage

The Icon sizes inline SVGs relative to the surrounding text and aligns them with the text baseline.

```html
<span class="with-icon">
  <svg class="icon" aria-hidden="true" focusable="false">
    <use href="#icon-star"></use>
  </svg>
  Star
</span>
```

## Recipes

### Recipe 1: Button with Icon

```html
<button class="with-icon">
  <svg class="icon" aria-hidden="true" focusable="false">
    <use href="#icon-download"></use>
  </svg>
  Download
</button>
```

**Why this works:**
- `.with-icon` uses `inline-flex` + `baseline` alignment
- The SVG scales with the button's font size automatically
- `aria-hidden="true"` prevents the icon from being announced — the button text provides the label
- `focusable="false"` prevents IE/Edge SVG focus issues

### Recipe 2: Icon-Only Button (Accessible)

```html
<button class="with-icon" aria-label="Close dialog">
  <svg class="icon" aria-hidden="true" focusable="false">
    <use href="#icon-close"></use>
  </svg>
</button>
```

**Why this works:**
- `aria-label` on the button provides the accessible name
- Icon is decorative (`aria-hidden="true"`)
- The icon still scales with the button's font size
- This pattern avoids the icon-only button anti-pattern (ELP_015)

### Recipe 3: Inline Status Indicators

```html
<ul class="stack" style="--space: var(--s-1)">
  <li class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false" style="color: green">
      <use href="#icon-check"></use>
    </svg>
    Tests passing
  </li>
  <li class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false" style="color: red">
      <use href="#icon-x"></use>
    </svg>
    Build failed
  </li>
  <li class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false" style="color: orange">
      <use href="#icon-alert"></use>
    </svg>
    Deploy pending
  </li>
</ul>
```

**Why this works:**
- Icons inherit size from the list item text
- Color on each SVG provides semantic meaning visually
- Text labels ensure meaning is not conveyed by color alone (WCAG 1.4.1)
- Stack provides consistent spacing between items

## Common Combinations

### Icon + Cluster (Social Links)
```html
<nav class="cluster" aria-label="Social links">
  <a href="#" class="with-icon" aria-label="Twitter">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-twitter"></use></svg>
  </a>
  <a href="#" class="with-icon" aria-label="GitHub">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-github"></use></svg>
  </a>
  <a href="#" class="with-icon" aria-label="RSS">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-rss"></use></svg>
  </a>
</nav>
```

### Icon + Stack (Feature List)
```html
<ul class="stack">
  <li class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-check"></use></svg>
    Feature one included
  </li>
  <li class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-check"></use></svg>
    Feature two included
  </li>
</ul>
```

### Icon + Box (Alert)
```html
<div class="box">
  <p class="with-icon">
    <svg class="icon" aria-hidden="true" focusable="false"><use href="#icon-info"></use></svg>
    This is an informational message.
  </p>
</div>
```

## Verification Checklist

- [ ] Icon scales with surrounding text (try different font sizes)
- [ ] Icon aligns with the text baseline
- [ ] `aria-hidden="true"` is present on decorative icons
- [ ] Icon-only buttons have `aria-label` on the interactive element
- [ ] Space between icon and text is controlled by `--space`
- [ ] Progressive enhancement: `1cap` used where supported, `0.75em` as fallback

---

# Imposter Cookbook

## Basic Usage

The Imposter superimposes an element over its positioned parent, centered both vertically and horizontally.

```html
<div style="position: relative">
  <p>Background content</p>
  <div class="imposter">
    <p>Overlaid content</p>
  </div>
</div>
```

## Recipes

### Recipe 1: Modal Dialog

```html
<div style="position: relative; min-block-size: 100vh">
  <main>
    <p>Page content beneath the modal...</p>
  </main>
  <div class="imposter" data-fixed data-contain style="--margin: var(--s2)">
    <div class="box stack" style="--padding: var(--s2); max-inline-size: 40ch">
      <h2>Confirm Action</h2>
      <p>Are you sure you want to proceed?</p>
      <div class="cluster" style="--justify: flex-end">
        <button type="button">Cancel</button>
        <button type="button">Confirm</button>
      </div>
    </div>
  </div>
</div>
```

**Why this works:**
- `data-fixed` positions relative to the viewport (not the parent)
- `data-contain` prevents the modal from overflowing the viewport
- `--margin` adds safe distance from viewport edges
- Box provides padding and visual boundary; Cluster aligns the buttons

### Recipe 2: Image Overlay Badge

```html
<div style="position: relative; display: inline-block">
  <div class="frame" style="--n: 16; --d: 9; max-inline-size: 30rem">
    <img src="product.jpg" alt="Product">
  </div>
  <div class="imposter" style="inset-block-start: auto; inset-inline-start: auto; inset-inline-end: var(--s-1); inset-block-end: var(--s-1); transform: none">
    <span class="box" data-invert style="--padding: var(--s-2)">SALE</span>
  </div>
</div>
```

**Why this works:**
- Imposter is repositioned to the bottom-right by overriding default offsets
- `transform: none` disables the centering translation
- Badge sits on top of the image without affecting its layout
- Inline-block wrapper creates a containing block for the Imposter

### Recipe 3: Loading Spinner

```html
<div style="position: relative; min-block-size: 20rem">
  <div class="grid" style="opacity: 0.3; pointer-events: none">
    <!-- dimmed content underneath -->
    <div class="box">Card 1</div>
    <div class="box">Card 2</div>
    <div class="box">Card 3</div>
  </div>
  <div class="imposter">
    <div class="stack" style="--space: var(--s-1); text-align: center">
      <div aria-hidden="true">⏳</div>
      <p>Loading...</p>
    </div>
  </div>
</div>
```

**Why this works:**
- Imposter centers the spinner over the loading content
- Content underneath is dimmed but still occupies space
- Absolute positioning keeps the spinner centered as content changes

## Common Combinations

### Imposter + Box (Tooltip)
```html
<div style="position: relative">
  <button>Hover me</button>
  <div class="imposter" style="inset-block-start: 100%; transform: translateX(-50%)">
    <div class="box" style="--padding: var(--s-2)">
      <p>Tooltip text</p>
    </div>
  </div>
</div>
```

### Imposter + Cover (Full-Screen Overlay)
```html
<div class="imposter" data-fixed data-contain>
  <div class="cover" style="--min-height: 80vh">
    <div></div>
    <div data-centered class="center">
      <div class="stack"><!-- modal content --></div>
    </div>
    <div></div>
  </div>
</div>
```

### Imposter + Cluster (Notification)
```html
<div style="position: relative">
  <div class="imposter" style="inset-block-start: var(--s1); inset-inline-end: var(--s1); inset-inline-start: auto; transform: none">
    <div class="box cluster" style="--padding: var(--s-1)">
      <span>New message received</span>
      <button>Dismiss</button>
    </div>
  </div>
</div>
```

## Verification Checklist

- [ ] Imposter is centered in its positioned parent by default
- [ ] Parent has `position: relative` (or use `data-fixed` for viewport)
- [ ] `data-contain` prevents overflow beyond parent boundaries
- [ ] `data-fixed` switches from absolute to fixed positioning
- [ ] `--margin` controls safe distance from parent edges when contained

---

# Reel Cookbook

## Basic Usage

The Reel creates a horizontal scrolling container for items that overflow inline.

```html
<div class="reel">
  <div>Item 1</div>
  <div>Item 2</div>
  <div>Item 3</div>
  <div>Item 4</div>
  <div>Item 5</div>
</div>
```

## Recipes

### Recipe 1: Image Carousel

```html
<div class="reel" style="--item-width: 20rem; --height: 15rem; --space: var(--s0)">
  <div class="frame"><img src="slide-1.jpg" alt="Slide 1"></div>
  <div class="frame"><img src="slide-2.jpg" alt="Slide 2"></div>
  <div class="frame"><img src="slide-3.jpg" alt="Slide 3"></div>
  <div class="frame"><img src="slide-4.jpg" alt="Slide 4"></div>
  <div class="frame"><img src="slide-5.jpg" alt="Slide 5"></div>
</div>
```

**Why this works:**
- `--item-width` gives each slide a fixed width
- `--height` constrains the Reel's block size
- Frames crop images to consistent aspect ratios
- Native scrollbar provides the interaction — no JavaScript carousel needed

### Recipe 2: Horizontal Card Scroller with Snap

```html
<div class="reel" data-snap style="--item-width: 16rem; --space: var(--s1)">
  <article class="box stack" style="--padding: var(--s1)">
    <h3>Topic One</h3>
    <p>A brief description of this topic.</p>
  </article>
  <article class="box stack" style="--padding: var(--s1)">
    <h3>Topic Two</h3>
    <p>Another card with different content.</p>
  </article>
  <article class="box stack" style="--padding: var(--s1)">
    <h3>Topic Three</h3>
    <p>And a third card to round it out.</p>
  </article>
  <article class="box stack" style="--padding: var(--s1)">
    <h3>Topic Four</h3>
    <p>Cards extend beyond the viewport.</p>
  </article>
</div>
```

**Why this works:**
- `data-snap` enables CSS scroll snap for precise card alignment
- Each card snaps to the start of the Reel on scroll
- Box + Stack gives each card consistent padding and internal spacing

### Recipe 3: Logo Banner (No Scrollbar)

```html
<div class="reel" data-no-bar style="--space: var(--s2); --item-width: 8rem">
  <img src="logo-1.svg" alt="Partner 1" class="icon">
  <img src="logo-2.svg" alt="Partner 2" class="icon">
  <img src="logo-3.svg" alt="Partner 3" class="icon">
  <img src="logo-4.svg" alt="Partner 4" class="icon">
  <img src="logo-5.svg" alt="Partner 5" class="icon">
</div>
```

**Why this works:**
- `data-no-bar` hides the scrollbar for a cleaner visual
- Generous spacing between logos (`--s2`)
- Users can still scroll via touch/trackpad/keyboard

## Common Combinations

### Reel + Frame (Consistent Media)
```html
<div class="reel" style="--item-width: 18rem">
  <div class="frame"><img src="a.jpg" alt="A"></div>
  <div class="frame"><img src="b.jpg" alt="B"></div>
  <div class="frame"><img src="c.jpg" alt="C"></div>
</div>
```

### Reel + Box (Scrollable Cards)
```html
<div class="reel" style="--item-width: 15rem">
  <div class="box stack"><!-- card 1 --></div>
  <div class="box stack"><!-- card 2 --></div>
  <div class="box stack"><!-- card 3 --></div>
</div>
```

### Reel + Stack (Content Scroller)
```html
<div class="stack">
  <h2>Featured Stories</h2>
  <div class="reel" style="--item-width: 20rem">
    <article class="stack"><!-- story 1 --></article>
    <article class="stack"><!-- story 2 --></article>
  </div>
</div>
```

## Verification Checklist

- [ ] Items scroll horizontally when they overflow
- [ ] Each item respects `--item-width` as its flex-basis
- [ ] Spacing between items is consistent via `margin-inline-start`
- [ ] `data-no-bar` hides the scrollbar
- [ ] `data-snap` enables scroll snap alignment at item boundaries
- [ ] Images with `block-size: 100%` fill the Reel height

---

# Sidebar Cookbook

## Basic Usage

The Sidebar creates a two-element layout where one panel has an intrinsic width and the other fills the remaining space, stacking vertically when there isn't enough room.

```html
<div class="with-sidebar">
  <nav>Sidebar content</nav>
  <main>Main content</main>
</div>
```

## Recipes

### Recipe 1: Documentation Layout

```html
<div class="with-sidebar" style="--side-width: 16rem; --content-min: 60%">
  <nav class="stack" style="--space: var(--s-1)">
    <h2>Docs</h2>
    <ul class="stack" style="--space: var(--s-2)">
      <li><a href="#">Getting Started</a></li>
      <li><a href="#">API Reference</a></li>
      <li><a href="#">Examples</a></li>
      <li><a href="#">FAQ</a></li>
    </ul>
  </nav>
  <main class="stack">
    <h1>Getting Started</h1>
    <p>Welcome to the documentation...</p>
  </main>
</div>
```

**Why this works:**
- `--side-width: 16rem` gives the nav a comfortable basis
- `--content-min: 60%` triggers stacking when main content gets too narrow
- No media queries — the layout decides when to switch

### Recipe 2: Product Page (Image + Details)

```html
<div class="with-sidebar" style="--side-width: 25rem; --content-min: 50%; --space: var(--s2)">
  <div class="frame" style="--n: 1; --d: 1">
    <img src="product.jpg" alt="Product photo">
  </div>
  <div class="stack">
    <h1>Product Name</h1>
    <p class="price">$49.99</p>
    <p>Product description with key details...</p>
    <button>Add to Cart</button>
  </div>
</div>
```

**Why this works:**
- Image gets a fixed basis via `--side-width`, content flexes
- Frame keeps the image at a 1:1 aspect ratio
- Stacks when viewport can't fit both comfortably

### Recipe 3: Email Composition (Sidebar Right)

```html
<div class="with-sidebar" data-no-stretch style="--side-width: 12rem; --content-min: 55%">
  <div class="stack">
    <label>To <input type="email"></label>
    <label>Subject <input type="text"></label>
    <label>Message <textarea rows="10"></textarea></label>
    <button>Send</button>
  </div>
  <aside class="box">
    <div class="stack" style="--space: var(--s-1)">
      <h3>Quick Contacts</h3>
      <ul class="stack" style="--space: var(--s-2)">
        <li>alice@example.com</li>
        <li>bob@example.com</li>
      </ul>
    </div>
  </aside>
</div>
```

**Why this works:**
- When the sidebar element is `:last-child`, it appears on the inline end
- `data-no-stretch` prevents the sidebar from stretching to full height
- The form (`:first-child`) is the main content here, sidebar is the contact list

## Common Combinations

### Sidebar + Center (Page Shell)
```html
<div class="center" style="--measure: 80rem">
  <div class="with-sidebar">
    <nav><!-- sidebar --></nav>
    <main><!-- content --></main>
  </div>
</div>
```

### Sidebar + Stack (Admin Panel)
```html
<div class="with-sidebar">
  <aside class="stack">
    <h2>Menu</h2>
    <nav><!-- links --></nav>
  </aside>
  <main class="stack">
    <h1>Dashboard</h1>
    <p>Content...</p>
  </main>
</div>
```

### Sidebar + Grid (Filtered Gallery)
```html
<div class="with-sidebar" style="--side-width: 14rem">
  <aside class="stack">
    <h3>Filters</h3>
    <fieldset><!-- filter controls --></fieldset>
  </aside>
  <div class="grid" style="--min: 12rem">
    <!-- gallery items -->
  </div>
</div>
```

## Verification Checklist

- [ ] Sidebar (`:first-child`) has a fixed flex-basis
- [ ] Content (`:last-child`) grows to fill remaining space
- [ ] Layout stacks when content would be narrower than `--content-min`
- [ ] `data-no-stretch` prevents cross-axis stretching
- [ ] Exactly two direct children are present

---

# Stack Cookbook

## Basic Usage

The Stack applies vertical spacing between sibling elements.

```html
<div class="stack">
  <p>First paragraph</p>
  <p>Second paragraph</p>
  <p>Third paragraph</p>
</div>
```

## Recipes

### Recipe 1: Article Layout

```html
<article class="stack" style="--space: 1.5rem">
  <h1>Article Title</h1>
  <p class="meta">Published on January 1, 2024</p>
  <div class="stack" style="--space: 1rem">
    <p>First paragraph of content...</p>
    <p>Second paragraph of content...</p>
    <blockquote>A memorable quote</blockquote>
    <p>More content...</p>
  </div>
</article>
```

**Why this works:**
- Outer Stack provides generous spacing between major sections
- Inner Stack with tighter spacing for body content
- Nested Stacks maintain consistent vertical rhythm

### Recipe 2: Form with Split Submit

```html
<form class="stack" data-split-after="3">
  <label>Name <input type="text"></label>
  <label>Email <input type="email"></label>
  <label>Message <textarea></textarea></label>
  <button type="submit">Send</button>
</form>
```

**Why this works:**
- `data-split-after="3"` pushes the submit button to the bottom
- Form fills available height with button at bottom
- Good for sidebar forms or modal content

### Recipe 3: Card with Bottom Action

```html
<div class="box">
  <div class="stack" data-split-after="2">
    <h3>Card Title</h3>
    <p>Card description text that can vary in length.</p>
    <a href="#">Read more →</a>
  </div>
</div>
```

**Why this works:**
- Link always stays at bottom regardless of description length
- Cards align in Grid or Cluster layouts

## Common Combinations

### Stack + Center (Article Layout)
```html
<div class="center">
  <article class="stack">
    <!-- content -->
  </article>
</div>
```

### Stack + Box (Sidebar Panel)
```html
<aside class="box">
  <div class="stack">
    <h3>Related Links</h3>
    <ul><!-- links --></ul>
  </div>
</aside>
```

### Stack + Grid (Card Grid)
```html
<div class="grid">
  <div class="stack"><!-- card 1 --></div>
  <div class="stack"><!-- card 2 --></div>
  <div class="stack"><!-- card 3 --></div>
</div>
```

## Verification Checklist

- [ ] First child has no top margin
- [ ] All siblings have equal spacing
- [ ] Nested elements don't inherit spacing (unless recursive)
- [ ] splitAfter pushes content to bottom correctly

---

# Switcher Cookbook

## Basic Usage

The Switcher creates equal-width columns that automatically stack when the container is too narrow.

```html
<div class="switcher">
  <div>Column 1</div>
  <div>Column 2</div>
  <div>Column 3</div>
</div>
```

## Recipes

### Recipe 1: Pricing Comparison

```html
<div class="switcher" style="--threshold: 35rem; --space: var(--s1)">
  <div class="box stack">
    <h3>Free</h3>
    <p class="price">$0/mo</p>
    <ul class="stack" style="--space: var(--s-1)">
      <li>5 projects</li>
      <li>Basic support</li>
    </ul>
    <a href="#">Sign Up</a>
  </div>
  <div class="box stack">
    <h3>Pro</h3>
    <p class="price">$29/mo</p>
    <ul class="stack" style="--space: var(--s-1)">
      <li>Unlimited projects</li>
      <li>Priority support</li>
    </ul>
    <a href="#">Start Trial</a>
  </div>
  <div class="box stack">
    <h3>Enterprise</h3>
    <p class="price">Custom</p>
    <ul class="stack" style="--space: var(--s-1)">
      <li>Custom integrations</li>
      <li>Dedicated support</li>
    </ul>
    <a href="#">Contact Us</a>
  </div>
</div>
```

**Why this works:**
- Three equal-width columns above `--threshold`, full-width stack below
- No media queries — the container width determines the layout
- Each card is a Box + Stack for consistent padding and vertical rhythm

### Recipe 2: Feature Highlights (with Limit)

```html
<div class="switcher" data-limit="3" style="--threshold: 25rem; --space: var(--s2)">
  <div class="stack" style="--space: var(--s-1)">
    <h3>Fast</h3>
    <p>Built for performance from the ground up.</p>
  </div>
  <div class="stack" style="--space: var(--s-1)">
    <h3>Secure</h3>
    <p>Enterprise-grade security by default.</p>
  </div>
  <div class="stack" style="--space: var(--s-1)">
    <h3>Scalable</h3>
    <p>Grows with your team and traffic.</p>
  </div>
  <div class="stack" style="--space: var(--s-1)">
    <h3>Reliable</h3>
    <p>99.99% uptime SLA guaranteed.</p>
  </div>
</div>
```

**Why this works:**
- `data-limit="3"` ensures maximum 3 columns per row
- The 4th item wraps to a new row at full width
- Larger spacing (`--s2`) separates the feature blocks visually

### Recipe 3: Two-Column Form

```html
<div class="switcher" style="--threshold: 30rem; --space: var(--s1)">
  <div class="stack">
    <label>First Name <input type="text"></label>
    <label>Email <input type="email"></label>
  </div>
  <div class="stack">
    <label>Last Name <input type="text"></label>
    <label>Phone <input type="tel"></label>
  </div>
</div>
```

**Why this works:**
- Two-column form on wide screens, single column on narrow
- Fields pair logically (first/last name, email/phone)
- Stacking threshold keeps fields readable

## Common Combinations

### Switcher + Box (Card Row)
```html
<div class="switcher">
  <div class="box stack"><!-- card 1 --></div>
  <div class="box stack"><!-- card 2 --></div>
  <div class="box stack"><!-- card 3 --></div>
</div>
```

### Switcher + Center (Centered Columns)
```html
<div class="center">
  <div class="switcher" style="--threshold: 25rem">
    <div>Column A</div>
    <div>Column B</div>
  </div>
</div>
```

### Switcher + Cover (Hero Split)
```html
<div class="cover" style="--min-height: 80vh">
  <div data-centered class="switcher" style="--threshold: 35rem">
    <div class="stack">
      <h1>Hero Title</h1>
      <p>Description text...</p>
    </div>
    <div class="frame">
      <img src="hero.jpg" alt="Hero image">
    </div>
  </div>
</div>
```

## Verification Checklist

- [ ] All columns are equal width above threshold
- [ ] Columns stack to full width below threshold
- [ ] `data-limit` caps the number of columns per row
- [ ] The switch happens based on container width, not viewport
- [ ] Gap is consistent in both horizontal and vertical states
