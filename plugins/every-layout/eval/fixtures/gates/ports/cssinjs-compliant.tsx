// Gate fixture — ports-lint.sh positive case (compliant port pattern).
// EXPECTED (--strict): exit 0, no findings.
// The compliant shape: className for the primitive, style carries ONLY
// --custom-property parameters (the primitive's instance API), and the
// primitive CSS ships once as a stylesheet import.
import './primitives.css';
import React from 'react';

type StackProps = {
  children: React.ReactNode;
  space?: string;
  as?: keyof JSX.IntrinsicElements;
};

export function Stack({ children, space = 'var(--s1)', as: Component = 'div', ...props }: StackProps) {
  return (
    <Component className="stack" style={{ '--space': space }} {...props}>
      {children}
    </Component>
  );
}
