/**
 * Grid Component
 * Responsive grid with intrinsic sizing
 *
 * Styling lives in CSS (demos/archive-site/src/styles/primitives.css /
 * demos/every-layout.css) — this component only emits the `.grid`
 * className plus --custom-property parameters (ELA_005). It never injects
 * a <style> tag and never builds a declaration object.
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
  const vars = { '--min': min, '--space': space } satisfies Record<string, string>;

  return (
    <Component
      ref={ref as any}
      className={`grid ${className}`.trim()}
      style={{ ...vars, ...style }}
      {...props}
    >
      {children}
    </Component>
  );
});

Grid.displayName = 'Grid';

export default Grid;
