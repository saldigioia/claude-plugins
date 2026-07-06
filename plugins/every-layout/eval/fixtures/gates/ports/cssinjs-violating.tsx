// Gate fixture — ports-lint.sh negative case (ELA_005 CSS-in-JS patterns).
// EXPECTED (--strict): exit 1 with at least 5 findings:
//   - styled-components import
//   - React.CSSProperties style-object typing
//   - runtime <style> injection
//   - bespoke keys (padding, color) in an inline style object
//   - styled.button tagged template
import styled from 'styled-components';
import React from 'react';

const styles: React.CSSProperties = {
  padding: 'var(--s1)',
  display: 'flex',
};

export function BadBox({ children }: { children: React.ReactNode }) {
  return (
    <>
      <style>{`.box { padding: var(--s1); }`}</style>
      <div className="box" style={{ padding: 'var(--s1)', color: 'red' }}>
        {children}
      </div>
    </>
  );
}

const Button = styled.button`
  color: red;
`;
