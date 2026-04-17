# Form Layout Patterns

Canonical primitive compositions for common form layouts. No new primitives — every pattern composes from the existing 13.

---

## Pattern 1: Stacked Label + Input (default)

The simplest and most accessible form pattern. Each label-input pair is a Stack child.

```html
<form class="stack">
  <div>
    <label for="name">Name</label>
    <input id="name" type="text">
  </div>
  <div>
    <label for="email">Email</label>
    <input id="email" type="email">
  </div>
  <button type="submit">Submit</button>
</form>
```

```css
/* Stack (ELC_STACK) handles vertical rhythm */
form.stack > * + * { margin-block-start: var(--s1); }

/* Labels above inputs — natural reading order, no layout needed */
label { display: block; margin-block-end: var(--s-2); }
input { inline-size: 100%; }
```

**Primitives:** ELC_STACK
**When to use:** Most forms. This is the default — deviate only with justification.

---

## Pattern 2: Inline Label + Input (Sidebar)

Label and input side by side, stacking on narrow containers.

```html
<form class="stack">
  <div class="with-sidebar">
    <label for="name">Full name</label>
    <input id="name" type="text">
  </div>
  <div class="with-sidebar">
    <label for="email">Email address</label>
    <input id="email" type="email">
  </div>
  <button type="submit">Submit</button>
</form>
```

```css
/* Sidebar (ELC_SIDEBAR) — label is the side, input is the content */
.with-sidebar { display: flex; flex-wrap: wrap; gap: var(--s-1); align-items: baseline; }
.with-sidebar > label { flex-basis: 10rem; flex-grow: 1; }
.with-sidebar > input { flex-basis: 0; flex-grow: 999; min-inline-size: 60%; }
```

**Primitives:** ELC_STACK + ELC_SIDEBAR
**When to use:** Settings forms, admin panels where labels are short and screen space is wide. The `min-inline-size: 60%` triggers stacking when the container narrows — no media query needed.

---

## Pattern 3: Grouped Fieldset

Related fields grouped with a legend, separated by larger Stack spacing.

```html
<form class="stack" style="--space: var(--s2)">
  <fieldset class="stack" style="--space: var(--s0)">
    <legend>Personal Information</legend>
    <div>
      <label for="first">First name</label>
      <input id="first" type="text">
    </div>
    <div>
      <label for="last">Last name</label>
      <input id="last" type="text">
    </div>
  </fieldset>
  <fieldset class="stack" style="--space: var(--s0)">
    <legend>Contact</legend>
    <div>
      <label for="phone">Phone</label>
      <input id="phone" type="tel">
    </div>
  </fieldset>
  <button type="submit">Submit</button>
</form>
```

```css
/* Outer Stack has larger spacing between fieldsets */
/* Inner Stacks have tighter spacing between fields */
fieldset { border: none; padding: 0; margin: 0; }
legend { font-weight: bold; margin-block-end: var(--s-1); }
```

**Primitives:** Nested ELC_STACK
**Principle:** ELP_008 (child-only layout effects) — outer Stack controls fieldset spacing, inner Stack controls field spacing. No leakage.

---

## Pattern 4: Multi-Column Form (Switcher)

Two or more fields side by side that stack below a threshold.

```html
<form class="stack">
  <div class="switcher">
    <div>
      <label for="first">First name</label>
      <input id="first" type="text">
    </div>
    <div>
      <label for="last">Last name</label>
      <input id="last" type="text">
    </div>
  </div>
  <div>
    <label for="email">Email</label>
    <input id="email" type="email">
  </div>
  <button type="submit">Submit</button>
</form>
```

```css
/* Switcher (ELC_SWITCHER) — columns when wide, stacked when narrow */
.switcher { display: flex; flex-wrap: wrap; gap: var(--s1); }
.switcher > * { flex-grow: 1; flex-basis: calc((20rem - 100%) * 999); }

input { inline-size: 100%; }
```

**Primitives:** ELC_STACK + ELC_SWITCHER
**When to use:** Name pairs (first/last), address lines (city/state/zip), date ranges (from/to). The threshold determines when columns collapse — no media query.

---

## Pattern 5: Error Message Positioning

Error messages appear below their input, within the Stack rhythm.

```html
<form class="stack">
  <div class="stack" style="--space: var(--s-2)">
    <label for="email">Email</label>
    <input id="email" type="email" aria-describedby="email-error" aria-invalid="true">
    <p id="email-error" role="alert" class="field-error">Please enter a valid email.</p>
  </div>
  <button type="submit">Submit</button>
</form>
```

```css
/* Tight inner Stack keeps error close to its input */
.field-error {
  color: var(--color-error, #b91c1c);
  font-size: var(--s-1);
}
```

**Primitives:** Nested ELC_STACK with tighter `--space`
**Accessibility:** `aria-describedby` links error to input, `role="alert"` announces to screen readers, `aria-invalid="true"` marks the field.

---

## Pattern 6: Submit Button Alignment (Cluster)

Button group at the form bottom — primary and secondary actions.

```html
<form class="stack">
  <!-- fields above -->
  <div class="cluster" style="--justify: flex-end">
    <button type="button">Cancel</button>
    <button type="submit">Save</button>
  </div>
</form>
```

```css
/* Cluster (ELC_CLUSTER) — buttons wrap if needed, aligned to end */
.cluster { display: flex; flex-wrap: wrap; gap: var(--s-1); }
```

**Primitives:** ELC_STACK + ELC_CLUSTER
**When to use:** Any form with multiple actions. The Cluster handles wrapping on narrow screens. `justify-content: flex-end` pushes buttons to the inline end (right in LTR, left in RTL — logical alignment).

---

## Pattern 7: Search Form (Cluster)

Inline search with input and button side by side.

```html
<form role="search" class="cluster">
  <label for="search" class="visually-hidden">Search</label>
  <input id="search" type="search" placeholder="Search...">
  <button type="submit">Search</button>
</form>
```

```css
.cluster > input { flex-grow: 1; min-inline-size: 15rem; }
```

**Primitives:** ELC_CLUSTER
**When to use:** Header search bars, filter inputs. The Cluster wraps the button below the input on narrow containers.

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| CSS Grid for form layout | Overly rigid, breaks on dynamic field counts | Use Stack + Switcher |
| `display: table` for label alignment | Physical, fragile, inaccessible | Use Sidebar |
| Fixed-width labels (`width: 120px`) | Breaks i18n, violates ELP_002 | Use `flex-basis` in Sidebar |
| `float: left` on labels | Fragile, requires clearfix | Use Sidebar or Stack |
| `position: absolute` on error messages | Removes from flow, causes overlap | Use tight inner Stack |
| Media queries for form column changes | Couples to viewport (ELP_009) | Use Switcher threshold |

---

## Decision Tree

```
Is each field on its own line?
├─ Yes → Stack (Pattern 1)
└─ No → Are labels beside inputs?
    ├─ Yes → Sidebar (Pattern 2)
    └─ No → Are fields side by side?
        ├─ Yes → Do they always stay side by side?
        │   ├─ Yes → Cluster
        │   └─ No → Switcher (Pattern 4)
        └─ No → Stack (default)
```
