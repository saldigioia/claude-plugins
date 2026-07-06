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
//
// To split a stack (push remaining children to the end), put
// data-split-after on the child after which the split happens:
// `.stack > [data-split-after] { margin-block-end: auto }` — there is no
// numeric splitAfter prop; the DOM attribute is the API (ELA_005: framework
// runtimes select CSS hooks, they do not compute layout declarations).
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
  justify?: CSSProperties['justifyContent'];
  align?: CSSProperties['alignItems'];
}

// Sidebar
//
// Which child is the sidebar is controlled by DOM order (first child is the
// fixed-width side, last child is the flexible content), matching
// `.with-sidebar > :first-child` / `:last-child` in primitives.css — there
// is no `side` prop, since swapping it would require the runtime to compute
// CSS declarations rather than select an existing class/attribute hook
// (ELA_005). Put the sidebar element first or last in JSX children instead.
export interface SidebarProps extends BaseLayoutProps {
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
