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
