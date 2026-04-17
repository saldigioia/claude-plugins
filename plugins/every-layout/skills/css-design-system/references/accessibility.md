# Accessibility Patterns

Source: `decisions.md` §11

## Required on Every Page

| Pattern | Element | Detail |
|---------|---------|--------|
| Skip link | `<a href="#main" class="skip-link">Skip to content</a>` | First element in `<body>`. Visually hidden until `:focus`. Uses `clip-path: inset(50%)` not `display: none`. |
| Main landmark | `<main id="main">` | Target of skip link. Every page must have exactly one. |
| Language | `<html lang="en">` | Required. Set to content language. |
| Color scheme | `color-scheme: light dark` on `:root` | Tells browser to render form controls in OS-matching mode. |

## Interactive Element Patterns

| Pattern | Rule |
|---------|------|
| Focus ring | `:focus-visible { outline: 3px solid var(--color-focus); outline-offset: 2px; }` on all interactive elements. Never `outline: none` without a replacement. |
| Hover reveal | Secondary actions (share buttons, etc.) start at `opacity: 0` and reveal on parent `:hover` AND own `:focus-visible`. Both are required -- hover alone fails keyboard users. |
| Active press | `translate: 0 1px` on `:active` (see transitions.md). |
| Disabled state | `opacity: 0.5; pointer-events: none; cursor: not-allowed;` with `aria-disabled="true"` (not `disabled` attribute on non-form elements). |

## Toast / Live Region

| Rule | Detail |
|------|--------|
| Element | `<div role="status" aria-live="polite" hidden>` |
| Position | `position: fixed; inset-block-end: var(--s1); inset-inline-start: 50%; transform: translateX(-50%)` |
| Behavior | JS sets `hidden` to false, then re-hides after timeout (~2s). Content change is announced by AT. |
| Motion | Entry animation must respect `prefers-reduced-motion`. |

## SVG Icon Rules

| Type | Attributes | Rule |
|------|-----------|------|
| Decorative (inside a labeled button) | `aria-hidden="true" focusable="false"` | Never announce decorative icons |
| Meaningful (standalone informational) | `role="img" aria-labelledby="title-id"` with `<title>` + `<desc>` | Always provide accessible name |

## List Semantics (Safari VoiceOver Bug)

When applying `list-style: none` to `<ul>` or `<ol>`, Safari VoiceOver stops announcing it as a list. Fix: add `role="list"` explicitly to the element. Apply globally in the reset stylesheet.

## `:target` Deep-Link Highlighting

Hash-linked content (e.g., `#photo-123`) should receive a visible highlight when navigated to:

```css
.item:target {
  outline: var(--border-thick) solid var(--color-focus);
  outline-offset: var(--s-2);
}
```

This is an accessibility AND UX pattern -- it tells the user what they just linked to.
