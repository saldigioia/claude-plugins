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
