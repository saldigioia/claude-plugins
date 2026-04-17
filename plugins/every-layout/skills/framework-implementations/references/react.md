# React Implementation

All 13 Every Layout primitives as React components with TypeScript, plus shared types and barrel export.

## Shared Types (types.ts)

```tsx
/**
 * Every Layout - React Component Types
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

import { CSSProperties, ReactNode, HTMLAttributes } from 'react';

// Base props that all layout components share
export interface BaseLayoutProps extends HTMLAttributes<HTMLElement> {
  children?: ReactNode;
  as?: keyof JSX.IntrinsicElements;
  className?: string;
  style?: CSSProperties;
}

// Stack
export interface StackProps extends BaseLayoutProps {
  space?: string;
  recursive?: boolean;
  splitAfter?: number;
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
  justify?: CSSProperties['justifyContent'];
  align?: CSSProperties['alignItems'];
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
  limit?: number;
}

// Cover
export interface CoverProps extends BaseLayoutProps {
  centered?: string;
  space?: string;
  minHeight?: string;
  noPad?: boolean;
}

// Grid
export interface GridProps extends BaseLayoutProps {
  min?: string;
  space?: string;
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
  name?: string;
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
  padding = 'var(--s1)',
  borderWidth = 'var(--border-thin)',
  invert = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    padding,
    borderWidth,
    borderStyle: 'solid',
    color: invert ? 'var(--color-light)' : 'var(--color-dark)',
    backgroundColor: invert ? 'var(--color-dark)' : 'var(--color-light)',
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`box ${invert ? 'box--invert' : ''} ${className}`.trim()}
      style={styles}
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
  max = 'var(--measure)',
  gutters = 'var(--s1)',
  intrinsic = false,
  andText = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    boxSizing: 'content-box',
    maxInlineSize: max,
    marginInline: 'auto',
    paddingInline: gutters,
    ...(intrinsic && {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
    }),
    ...(andText && { textAlign: 'center' }),
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`center ${className}`.trim()}
      style={styles}
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
  space = 'var(--s1)',
  justify = 'flex-start',
  align = 'center',
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    display: 'flex',
    flexWrap: 'wrap',
    gap: space,
    justifyContent: justify,
    alignItems: align,
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`cluster ${className}`.trim()}
      style={styles}
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
  name,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    containerType: 'inline-size',
    ...(name && { containerName: name }),
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`container ${className}`.trim()}
      style={styles}
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
 * Vertical centering with optional header/footer
 */

import React, { forwardRef } from 'react';
import { CoverProps } from './types';

export const Cover = forwardRef<HTMLElement, CoverProps>(({
  children,
  as: Component = 'div',
  centered = '[data-centered]',
  space = 'var(--s1)',
  minHeight = '100vh',
  noPad = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--min-height': minHeight,
    '--space': space,
    display: 'flex',
    flexDirection: 'column',
    minBlockSize: minHeight,
    ...(!noPad && { padding: space }),
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .cover > * { margin-block: var(--space, var(--s1)); }
    .cover > :first-child:not(${centered}) { margin-block-start: 0; }
    .cover > :last-child:not(${centered}) { margin-block-end: 0; }
    .cover > ${centered} { margin-block: auto; }
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`cover ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
  );
});

Cover.displayName = 'Cover';

export default Cover;
```

## Frame.tsx

```tsx
/**
 * Frame Component
 * Aspect ratio container for media
 */

import React, { forwardRef } from 'react';
import { FrameProps } from './types';

export const Frame = forwardRef<HTMLElement, FrameProps>(({
  children,
  as: Component = 'div',
  ratio = '16/9',
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    aspectRatio: ratio,
    overflow: 'hidden',
    display: 'flex',
    justifyContent: 'center',
    alignItems: 'center',
    ...style,
  };

  const childStyles = `
    .frame > img,
    .frame > video {
      inline-size: 100%;
      block-size: 100%;
      object-fit: cover;
    }
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`frame ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
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
  min = '15rem',
  space = 'var(--s1)',
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    display: 'grid',
    gap: space,
    gridTemplateColumns: `repeat(auto-fit, minmax(min(${min}, 100%), 1fr))`,
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`grid ${className}`.trim()}
      style={styles}
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
  space = '0.5em',
  label,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--space': space,
    display: 'inline-flex',
    alignItems: 'baseline',
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .with-icon .icon {
      height: 0.75em;
      height: 1cap;
      width: 0.75em;
      width: 1cap;
    }
    .with-icon .icon {
      margin-inline-end: var(--space, 0.5em);
    }
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`with-icon ${className}`.trim()}
        style={styles}
        role={label ? 'img' : undefined}
        aria-label={label}
        {...props}
      >
        {children}
      </Component>
    </>
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
  margin = '0px',
  fixed = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    position: fixed ? 'fixed' : 'absolute',
    insetBlockStart: '50%',
    insetInlineStart: '50%',
    transform: 'translate(-50%, -50%)',
    ...(!breakout && {
      overflow: 'auto',
      maxInlineSize: `calc(100% - (${margin} * 2))`,
      maxBlockSize: `calc(100% - (${margin} * 2))`,
    }),
    ...style,
  };

  return (
    <Component
      ref={ref as any}
      className={`imposter ${className}`.trim()}
      style={styles}
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
  itemWidth = 'auto',
  space = 'var(--s1)',
  height = 'auto',
  noBar = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--item-width': itemWidth,
    '--space': space,
    '--height': height,
    display: 'flex',
    blockSize: height,
    overflowX: 'auto',
    overflowY: 'hidden',
    ...(noBar && { scrollbarWidth: 'none' as any }),
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .reel > * {
      flex: 0 0 var(--item-width, auto);
    }
    .reel > img {
      block-size: 100%;
      flex-basis: auto;
      width: auto;
    }
    .reel > * + * {
      margin-inline-start: var(--space, var(--s1));
    }
    ${noBar ? `
    .reel::-webkit-scrollbar { display: none; }
    ` : ''}
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`reel ${noBar ? 'reel--no-bar' : ''} ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
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
  sideWidth = '20rem',
  contentMin = '50%',
  space = 'var(--s1)',
  noStretch = false,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--side-width': sideWidth,
    '--content-min': contentMin,
    '--space': space,
    display: 'flex',
    flexWrap: 'wrap',
    gap: space,
    ...(noStretch && { alignItems: 'flex-start' }),
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .with-sidebar > * { flex-grow: 1; }
    .with-sidebar > :${side === 'left' ? 'first' : 'last'}-child {
      flex-basis: var(--side-width);
    }
    .with-sidebar > :${side === 'left' ? 'last' : 'first'}-child {
      flex-basis: 0;
      flex-grow: 999;
      min-inline-size: var(--content-min);
    }
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`with-sidebar ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
  );
});

Sidebar.displayName = 'Sidebar';

export default Sidebar;
```

## Stack.tsx

```tsx
/**
 * Stack Component
 * Vertical spacing between sibling elements
 */

import React, { forwardRef } from 'react';
import { StackProps } from './types';

export const Stack = forwardRef<HTMLElement, StackProps>(({
  children,
  as: Component = 'div',
  space = 'var(--s1)',
  recursive = false,
  splitAfter,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--space': space,
    display: 'flex',
    flexDirection: 'column',
    justifyContent: 'flex-start',
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .stack > * { margin-block: 0; }
    .stack > * + * { margin-block-start: var(--space, 1.5rem); }
    ${recursive ? '.stack * + * { margin-block-start: var(--space, 1.5rem); }' : ''}
    ${splitAfter ? `.stack > :nth-child(${splitAfter}) { margin-block-end: auto; }` : ''}
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`stack ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
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
  threshold = '30rem',
  space = 'var(--s1)',
  limit,
  className = '',
  style,
  ...props
}, ref) => {
  const styles: React.CSSProperties = {
    '--threshold': threshold,
    '--space': space,
    display: 'flex',
    flexWrap: 'wrap',
    gap: space,
    ...style,
  } as React.CSSProperties;

  const childStyles = `
    .switcher > * {
      flex-grow: 1;
      flex-basis: calc((var(--threshold, 30rem) - 100%) * 999);
    }
    ${limit ? `
    .switcher > :nth-last-child(n+${limit + 1}),
    .switcher > :nth-last-child(n+${limit + 1}) ~ * {
      flex-basis: 100%;
    }` : ''}
  `;

  return (
    <>
      <style>{childStyles}</style>
      <Component
        ref={ref as any}
        className={`switcher ${className}`.trim()}
        style={styles}
        {...props}
      >
        {children}
      </Component>
    </>
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

## Prop/Slot API Summary

All React components use `forwardRef`, accept `as` (polymorphic element), `className`, `style`, and spread remaining HTML attributes. Children are passed via `children` prop.

| Component | Props | Defaults |
|-----------|-------|----------|
| Box | `padding`, `borderWidth`, `invert` | `var(--s1)`, `var(--border-thin)`, `false` |
| Center | `max`, `gutters`, `intrinsic`, `andText` | `var(--measure)`, `var(--s1)`, `false`, `false` |
| Cluster | `space`, `justify`, `align` | `var(--s1)`, `flex-start`, `center` |
| Container | `name` | `undefined` |
| Cover | `centered`, `space`, `minHeight`, `noPad` | `[data-centered]`, `var(--s1)`, `100vh`, `false` |
| Frame | `ratio` | `16/9` |
| Grid | `min`, `space` | `15rem`, `var(--s1)` |
| Icon | `space`, `label` | `0.5em`, `undefined` |
| Imposter | `breakout`, `margin`, `fixed` | `false`, `0px`, `false` |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `auto`, `var(--s1)`, `auto`, `false` |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `left`, `20rem`, `50%`, `var(--s1)`, `false` |
| Stack | `space`, `recursive`, `splitAfter` | `var(--s1)`, `false`, `undefined` |
| Switcher | `threshold`, `space`, `limit` | `30rem`, `var(--s1)`, `undefined` |
