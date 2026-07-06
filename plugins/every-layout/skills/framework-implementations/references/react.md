# React Implementation

All 13 Every Layout primitives as React components with TypeScript, plus shared types and barrel export.

> **Prerequisite.** These components emit class names and `--custom-property` parameters only. They do not ship CSS. Load the canonical stylesheet once per app — see `references/vanilla.md` (source) / `demos/every-layout.css` (built artifact) — before rendering any primitive. Without it, every component below renders unstyled markup.

## Why no style objects

Axiom **ELA_005** (`skills/css-layout-engine/references/axioms.md`) makes layout a CSS problem: framework runtimes do not style the DOM. A `style={{ display: 'flex', ... }}` object is CSS-in-JS wearing a JSX costume, and `bin/ports-lint.sh --strict` fails the build the moment it sees a bespoke (non-`--`) key in a style object, a full declaration-object style typing, or a runtime injected stylesheet. The only legal `style` keys below are `--custom-property` parameters that the canonical stylesheet already reads via `var(--x, fallback)` — the component supplies the value, the stylesheet supplies every declaration.

## Shared Types (types.ts)

```tsx
/**
 * Every Layout - React Component Types
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 *
 * Every `style` prop below is typed as Record<string, string> — a bag of
 * --custom-property parameters, never CSS declarations (ELA_005).
 */

import { ReactNode, HTMLAttributes } from 'react';

// Base props that all layout components share
export interface BaseLayoutProps extends HTMLAttributes<HTMLElement> {
  children?: ReactNode;
  as?: keyof JSX.IntrinsicElements;
  className?: string;
  style?: Record<string, string>;
}

// Stack
export interface StackProps extends BaseLayoutProps {
  space?: string;
  recursive?: boolean;
}

// Box
export interface BoxProps extends BaseLayoutProps {
  padding?: string;
  borderWidth?: string;
  invert?: boolean;
}

// Center
export interface CenterProps extends BaseLayoutProps {
  max?: string;
  gutters?: string;
  intrinsic?: boolean;
  andText?: boolean;
}

// Cluster
export interface ClusterProps extends BaseLayoutProps {
  space?: string;
  justify?: string;
  align?: string;
}

// Sidebar
export interface SidebarProps extends BaseLayoutProps {
  side?: 'left' | 'right';
  sideWidth?: string;
  contentMin?: string;
  space?: string;
  noStretch?: boolean;
}

// Switcher
export interface SwitcherProps extends BaseLayoutProps {
  threshold?: string;
  space?: string;
  limit?: 2 | 3 | 4;
}

// Cover
export interface CoverProps extends BaseLayoutProps {
  space?: string;
  minHeight?: string;
  noPad?: boolean;
}

// Grid
export interface GridProps extends BaseLayoutProps {
  min?: string;
  space?: string;
  ragged?: boolean;
}

// Frame
export interface FrameProps extends BaseLayoutProps {
  ratio?: string;
}

// Reel
export interface ReelProps extends BaseLayoutProps {
  itemWidth?: string;
  space?: string;
  height?: string;
  noBar?: boolean;
}

// Imposter
export interface ImposterProps extends BaseLayoutProps {
  breakout?: boolean;
  margin?: string;
  fixed?: boolean;
}

// Icon
export interface IconProps extends BaseLayoutProps {
  space?: string;
  label?: string;
}

// Container
export interface ContainerProps extends BaseLayoutProps {
  containerName?: string;
}
```

## Box.tsx

```tsx
/**
 * Box Component
 * Padded container with optional border
 */

import React, { forwardRef } from 'react';
import { BoxProps } from './types';

export const Box = forwardRef<HTMLElement, BoxProps>(({
  children,
  as: Component = 'div',
  padding,
  borderWidth,
  invert = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (padding) vars['--padding'] = padding;
  if (borderWidth) vars['--border-width'] = borderWidth;

  return (
    <Component
      ref={ref as any}
      className={`box ${className}`.trim()}
      style={vars}
      data-invert={invert ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Box.displayName = 'Box';

export default Box;
```

## Center.tsx

```tsx
/**
 * Center Component
 * Horizontal centering with max-width constraint
 */

import React, { forwardRef } from 'react';
import { CenterProps } from './types';

export const Center = forwardRef<HTMLElement, CenterProps>(({
  children,
  as: Component = 'div',
  max,
  gutters,
  intrinsic = false,
  andText = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (max) vars['--measure'] = max;
  if (gutters) vars['--gutter'] = gutters;

  return (
    <Component
      ref={ref as any}
      className={`center ${className}`.trim()}
      style={vars}
      data-intrinsic={intrinsic ? '' : undefined}
      data-text={andText ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Center.displayName = 'Center';

export default Center;
```

## Cluster.tsx

```tsx
/**
 * Cluster Component
 * Flexible wrapping horizontal layout
 */

import React, { forwardRef } from 'react';
import { ClusterProps } from './types';

export const Cluster = forwardRef<HTMLElement, ClusterProps>(({
  children,
  as: Component = 'div',
  space,
  justify,
  align,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (space) vars['--space'] = space;
  if (justify) vars['--justify'] = justify;
  if (align) vars['--align'] = align;

  return (
    <Component
      ref={ref as any}
      className={`cluster ${className}`.trim()}
      style={vars}
      {...props}
    >
      {children}
    </Component>
  );
});

Cluster.displayName = 'Cluster';

export default Cluster;
```

## Container.tsx

```tsx
/**
 * Container Component
 * Container query context wrapper
 */

import React, { forwardRef } from 'react';
import { ContainerProps } from './types';

export const Container = forwardRef<HTMLElement, ContainerProps>(({
  children,
  as: Component = 'div',
  containerName,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (containerName) vars['--container-name'] = containerName;

  return (
    <Component
      ref={ref as any}
      className={`container ${className}`.trim()}
      style={vars}
      data-name={containerName ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Container.displayName = 'Container';

export default Container;
```

## Cover.tsx

```tsx
/**
 * Cover Component
 * Vertical centering with optional header/footer.
 * Mark the child that should absorb the remaining space with
 * `data-centered` — the stylesheet's `.cover > [data-centered]` rule
 * (see references/vanilla.md) handles the `margin-block: auto`.
 */

import React, { forwardRef } from 'react';
import { CoverProps } from './types';

export const Cover = forwardRef<HTMLElement, CoverProps>(({
  children,
  as: Component = 'div',
  space,
  minHeight,
  noPad = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (space) vars['--space'] = space;
  if (minHeight) vars['--min-height'] = minHeight;

  return (
    <Component
      ref={ref as any}
      className={`cover ${className}`.trim()}
      style={vars}
      data-no-pad={noPad ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Cover.displayName = 'Cover';

export default Cover;
```

## Frame.tsx

```tsx
/**
 * Frame Component
 * Aspect ratio container for media.
 * The stylesheet reads the ratio as two numbers, `--n` / `--d`
 * (`aspect-ratio: var(--n, 16) / var(--d, 9)` — see references/vanilla.md),
 * so the `ratio` prop is split here. That split is a parameter
 * computation, not a style declaration — it never touches `style` with
 * anything but `--n` and `--d`.
 */

import React, { forwardRef } from 'react';
import { FrameProps } from './types';

export const Frame = forwardRef<HTMLElement, FrameProps>(({
  children,
  as: Component = 'div',
  ratio,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (ratio) {
    const [n, d] = ratio.split('/').map((part) => part.trim());
    if (n) vars['--n'] = n;
    if (d) vars['--d'] = d;
  }

  return (
    <Component
      ref={ref as any}
      className={`frame ${className}`.trim()}
      style={vars}
      {...props}
    >
      {children}
    </Component>
  );
});

Frame.displayName = 'Frame';

export default Frame;
```

## Grid.tsx

```tsx
/**
 * Grid Component
 * Responsive grid with intrinsic sizing
 */

import React, { forwardRef } from 'react';
import { GridProps } from './types';

export const Grid = forwardRef<HTMLElement, GridProps>(({
  children,
  as: Component = 'div',
  min,
  space,
  ragged = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (min) vars['--min'] = min;
  if (space) vars['--space'] = space;

  return (
    <Component
      ref={ref as any}
      className={`grid ${className}`.trim()}
      style={vars}
      data-ragged={ragged ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Grid.displayName = 'Grid';

export default Grid;
```

## Icon.tsx

```tsx
/**
 * Icon Component
 * Inline SVG icon sizing and alignment
 */

import React, { forwardRef } from 'react';
import { IconProps } from './types';

export const Icon = forwardRef<HTMLElement, IconProps>(({
  children,
  as: Component = 'span',
  space,
  label,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (space) vars['--space'] = space;

  return (
    <Component
      ref={ref as any}
      className={`with-icon ${className}`.trim()}
      style={vars}
      role={label ? 'img' : undefined}
      aria-label={label}
      {...props}
    >
      {children}
    </Component>
  );
});

Icon.displayName = 'Icon';

export default Icon;
```

## Imposter.tsx

```tsx
/**
 * Imposter Component
 * Superimposed/overlay positioning
 */

import React, { forwardRef } from 'react';
import { ImposterProps } from './types';

export const Imposter = forwardRef<HTMLElement, ImposterProps>(({
  children,
  as: Component = 'div',
  breakout = false,
  margin,
  fixed = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (margin) vars['--margin'] = margin;

  return (
    <Component
      ref={ref as any}
      className={`imposter ${className}`.trim()}
      style={vars}
      data-contain={breakout ? undefined : ''}
      data-fixed={fixed ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Imposter.displayName = 'Imposter';

export default Imposter;
```

## Reel.tsx

```tsx
/**
 * Reel Component
 * Horizontal scrolling container
 */

import React, { forwardRef } from 'react';
import { ReelProps } from './types';

export const Reel = forwardRef<HTMLElement, ReelProps>(({
  children,
  as: Component = 'div',
  itemWidth,
  space,
  height,
  noBar = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (itemWidth) vars['--item-width'] = itemWidth;
  if (space) vars['--space'] = space;
  if (height) vars['--height'] = height;

  return (
    <Component
      ref={ref as any}
      className={`reel ${className}`.trim()}
      style={vars}
      data-no-bar={noBar ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Reel.displayName = 'Reel';

export default Reel;
```

## Sidebar.tsx

```tsx
/**
 * Sidebar Component
 * Two-element layout with intrinsic switching
 */

import React, { forwardRef } from 'react';
import { SidebarProps } from './types';

export const Sidebar = forwardRef<HTMLElement, SidebarProps>(({
  children,
  as: Component = 'div',
  side = 'left',
  sideWidth,
  contentMin,
  space,
  noStretch = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (sideWidth) vars['--side-width'] = sideWidth;
  if (contentMin) vars['--content-min'] = contentMin;
  if (space) vars['--space'] = space;

  return (
    <Component
      ref={ref as any}
      className={`with-sidebar ${className}`.trim()}
      style={vars}
      data-side={side === 'right' ? 'right' : undefined}
      data-no-stretch={noStretch ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Sidebar.displayName = 'Sidebar';

export default Sidebar;
```

> **Note on `side`.** `references/vanilla.md`'s `.with-sidebar` always treats `:first-child` as the sidebar. Placing the sidebar element last in markup (rather than a `side="right"` flip) is the zero-CSS way to mirror the layout — prefer that where you control markup order. `data-side="right"` above is a documented hook for a future stylesheet rule; it is inert until `every-layout.css` adds it, so treat `side` as advisory today.

## Stack.tsx

```tsx
/**
 * Stack Component
 * Vertical spacing between sibling elements.
 * To push a child and everything after it to the bottom (the old
 * `splitAfter` prop), put `data-split-after` on that child directly —
 * `.stack > [data-split-after] { margin-block-end: auto }` lives in the
 * stylesheet (see references/vanilla.md). The component has no numeric
 * splitAfter prop; it doesn't know which child is which.
 */

import React, { forwardRef } from 'react';
import { StackProps } from './types';

export const Stack = forwardRef<HTMLElement, StackProps>(({
  children,
  as: Component = 'div',
  space,
  recursive = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (space) vars['--space'] = space;

  return (
    <Component
      ref={ref as any}
      className={`stack ${className}`.trim()}
      style={vars}
      data-recursive={recursive ? '' : undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Stack.displayName = 'Stack';

export default Stack;
```

## Switcher.tsx

```tsx
/**
 * Switcher Component
 * Equal columns that switch to stack below threshold
 */

import React, { forwardRef } from 'react';
import { SwitcherProps } from './types';

export const Switcher = forwardRef<HTMLElement, SwitcherProps>(({
  children,
  as: Component = 'div',
  threshold,
  space,
  limit,
  className = '',
  style,
  ...props
}, ref) => {
  const vars: Record<string, string> = { ...style };
  if (threshold) vars['--threshold'] = threshold;
  if (space) vars['--space'] = space;

  return (
    <Component
      ref={ref as any}
      className={`switcher ${className}`.trim()}
      style={vars}
      data-limit={limit ?? undefined}
      {...props}
    >
      {children}
    </Component>
  );
});

Switcher.displayName = 'Switcher';

export default Switcher;
```

## Barrel Export (index.ts)

```typescript
/**
 * Every Layout - React Components
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

export { Stack } from './Stack';
export { Box } from './Box';
export { Center } from './Center';
export { Cluster } from './Cluster';
export { Sidebar } from './Sidebar';
export { Switcher } from './Switcher';
export { Cover } from './Cover';
export { Grid } from './Grid';
export { Frame } from './Frame';
export { Reel } from './Reel';
export { Imposter } from './Imposter';
export { Icon } from './Icon';
export { Container } from './Container';

// Re-export types
export type {
  BaseLayoutProps,
  StackProps,
  BoxProps,
  CenterProps,
  ClusterProps,
  SidebarProps,
  SwitcherProps,
  CoverProps,
  GridProps,
  FrameProps,
  ReelProps,
  ImposterProps,
  IconProps,
  ContainerProps,
} from './types';
```

## Usage Example

```tsx
import { Cover, Center, Stack, Box } from './components';

function Page() {
  return (
    <Cover style={{ '--min-height': '100vh' }}>
      <Box as="header" style={{ '--padding': 'var(--s0)' }}>Header</Box>
      <Center data-centered="" style={{ '--measure': '40ch' }}>
        <Stack style={{ '--space': 'var(--s2)' }}>
          <h1>Title</h1>
          <p data-split-after="">Push footer down from here.</p>
        </Stack>
      </Center>
      <Box as="footer" style={{ '--padding': 'var(--s0)' }}>Footer</Box>
    </Cover>
  );
}
```

## Prop/Slot API Summary

All React components use `forwardRef`, accept `as` (polymorphic element), `className`, `style` (a `Record<string, string>` of `--custom-property` parameters only — never a CSS declaration-object type), and spread remaining HTML attributes. Children are passed via `children` prop. Boolean variants render as data attributes, not style keys; the canonical rule for each lives in `references/vanilla.md`.

| Component | Props | Data Attributes |
|-----------|-------|------------------|
| Box | `padding`→`--padding`, `borderWidth`→`--border-width`, `invert` | `data-invert` |
| Center | `max`→`--measure`, `gutters`→`--gutter`, `intrinsic`, `andText` | `data-intrinsic`, `data-text` |
| Cluster | `space`→`--space`, `justify`→`--justify`, `align`→`--align` | — |
| Container | `containerName`→`--name` | `data-name` |
| Cover | `space`→`--space`, `minHeight`→`--min-height`, `noPad` | `data-no-pad`; mark a child `data-centered` |
| Frame | `ratio` (split into `--n`/`--d`) | — |
| Grid | `min`→`--min`, `space`→`--space`, `ragged` | `data-ragged` |
| Icon | `space`→`--space`, `label` (renders `aria-label`) | — |
| Imposter | `margin`→`--margin`, `breakout`, `fixed` | `data-contain` (default; omitted when `breakout`), `data-fixed` |
| Reel | `itemWidth`→`--item-width`, `space`→`--space`, `height`→`--height`, `noBar` | `data-no-bar` |
| Sidebar | `sideWidth`→`--side-width`, `contentMin`→`--content-min`, `space`→`--space`, `side`, `noStretch` | `data-no-stretch` (`side` is advisory — see note above Stack.tsx) |
| Stack | `space`→`--space`, `recursive` | `data-recursive`; mark a child `data-split-after` |
| Switcher | `threshold`→`--threshold`, `space`→`--space`, `limit` (`2`\|`3`\|`4`) | `data-limit` |

Every prop without an explicit default above has none in the component — the stylesheet's `var(--x, fallback)` supplies the fallback (e.g. `--space` falls back to `var(--s1)`), so the component only writes the custom property when a caller actually passes a value.
