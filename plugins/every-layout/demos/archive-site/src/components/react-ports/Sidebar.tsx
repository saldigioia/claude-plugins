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
