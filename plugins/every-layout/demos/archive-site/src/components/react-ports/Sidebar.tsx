/**
 * Sidebar Component
 * Two-element layout with intrinsic switching
 *
 * Styling lives in CSS (demos/archive-site/src/styles/primitives.css /
 * demos/every-layout.css) — this component only emits the `.with-sidebar`
 * className plus --custom-property parameters (ELA_005). It never injects
 * a <style> tag and never builds a declaration object.
 *
 * Which child is the sidebar is controlled by DOM order — the first child
 * is the fixed-width side, the last child is the flexible content
 * (`.with-sidebar > :first-child` / `:last-child`). There is no `side` prop.
 */

import React, { forwardRef } from 'react';
import { SidebarProps } from './types';

export const Sidebar = forwardRef<HTMLElement, SidebarProps>(({
  children,
  as: Component = 'div',
  sideWidth = '20rem',
  contentMin = '50%',
  space = 'var(--s1)',
  noStretch = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars = {
    '--side-width': sideWidth,
    '--content-min': contentMin,
    '--space': space,
  } satisfies Record<string, string>;

  return (
    <Component
      ref={ref as any}
      className={`with-sidebar ${className}`.trim()}
      data-no-stretch={noStretch ? '' : undefined}
      style={{ ...vars, ...style }}
      {...props}
    >
      {children}
    </Component>
  );
});

Sidebar.displayName = 'Sidebar';

export default Sidebar;
