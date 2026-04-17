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
