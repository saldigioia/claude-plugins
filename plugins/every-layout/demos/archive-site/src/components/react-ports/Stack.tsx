/**
 * Stack Component
 * Vertical spacing between sibling elements
 *
 * Styling lives in CSS (demos/archive-site/src/styles/primitives.css /
 * demos/every-layout.css) — this component only emits the `.stack`
 * className plus --custom-property parameters (ELA_005). It never injects
 * a <style> tag and never builds a declaration object.
 *
 * To split a stack, put `data-split-after` on the child after which the
 * split happens: `.stack > [data-split-after] { margin-block-end: auto }`.
 * There is no numeric splitAfter prop — the DOM attribute is the API.
 */

import React, { forwardRef } from 'react';
import { StackProps } from './types';

export const Stack = forwardRef<HTMLElement, StackProps>(({
  children,
  as: Component = 'div',
  space = 'var(--s1)',
  recursive = false,
  className = '',
  style,
  ...props
}, ref) => {
  const vars = { '--space': space } satisfies Record<string, string>;

  return (
    <Component
      ref={ref as any}
      className={`stack ${className}`.trim()}
      data-recursive={recursive ? '' : undefined}
      style={{ ...vars, ...style }}
      {...props}
    >
      {children}
    </Component>
  );
});

Stack.displayName = 'Stack';

export default Stack;
