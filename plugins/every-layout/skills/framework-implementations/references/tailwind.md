# Tailwind Implementation

Tailwind CSS plugin and design tokens for all 13 Every Layout primitives.

## plugin.js

```javascript
/**
 * Every Layout - Tailwind Plugin
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 * Version: 1.0.0
 */

const plugin = require('tailwindcss/plugin');

module.exports = plugin(function({ addComponents, addUtilities, theme }) {

  // Stack Component
  addComponents({
    '.stack': {
      display: 'flex',
      flexDirection: 'column',
      justifyContent: 'flex-start',
      '& > *': {
        marginBlock: '0',
      },
      '& > * + *': {
        marginBlockStart: 'var(--stack-space, 1.5rem)',
      },
    },
    '.stack-recursive': {
      '& * + *': {
        marginBlockStart: 'var(--stack-space, 1.5rem)',
      },
    },
  });

  // Box Component
  addComponents({
    '.box': {
      padding: 'var(--box-padding, 1rem)',
      borderWidth: 'var(--box-border, 1px)',
      borderStyle: 'solid',
      '& *': {
        color: 'inherit',
      },
    },
    '.box-invert': {
      color: 'var(--color-light, #fff)',
      backgroundColor: 'var(--color-dark, #000)',
    },
  });

  // Center Component
  addComponents({
    '.center': {
      boxSizing: 'content-box',
      maxInlineSize: 'var(--center-measure, 60ch)',
      marginInline: 'auto',
      paddingInline: 'var(--center-gutter, 1rem)',
    },
    '.center-intrinsic': {
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
    },
  });

  // Cluster Component
  addComponents({
    '.cluster': {
      display: 'flex',
      flexWrap: 'wrap',
      gap: 'var(--cluster-space, 1rem)',
      justifyContent: 'var(--cluster-justify, flex-start)',
      alignItems: 'var(--cluster-align, center)',
    },
  });

  // Sidebar Component
  addComponents({
    '.with-sidebar': {
      display: 'flex',
      flexWrap: 'wrap',
      gap: 'var(--sidebar-space, 1rem)',
      '& > *': {
        flexGrow: '1',
      },
      '& > :first-child': {
        flexBasis: 'var(--sidebar-width, 20rem)',
      },
      '& > :last-child': {
        flexBasis: '0',
        flexGrow: '999',
        minInlineSize: 'var(--sidebar-content-min, 50%)',
      },
    },
  });

  // Switcher Component
  addComponents({
    '.switcher': {
      display: 'flex',
      flexWrap: 'wrap',
      gap: 'var(--switcher-space, 1rem)',
      '& > *': {
        flexGrow: '1',
        flexBasis: 'calc((var(--switcher-threshold, 30rem) - 100%) * 999)',
      },
    },
  });

  // Cover Component
  addComponents({
    '.cover': {
      display: 'flex',
      flexDirection: 'column',
      minBlockSize: 'var(--cover-min-height, 100vh)',
      padding: 'var(--cover-padding, 1rem)',
      '& > *': {
        marginBlock: 'var(--cover-space, 1rem)',
      },
      '& > :first-child:not(.cover-centered)': {
        marginBlockStart: '0',
      },
      '& > :last-child:not(.cover-centered)': {
        marginBlockEnd: '0',
      },
    },
    '.cover-centered': {
      marginBlock: 'auto',
    },
  });

  // Grid Component
  addComponents({
    '.el-grid': {
      display: 'grid',
      gap: 'var(--grid-space, 1rem)',
      gridTemplateColumns: 'repeat(auto-fit, minmax(min(var(--grid-min, 15rem), 100%), 1fr))',
    },
  });

  // Frame Component
  addComponents({
    '.frame': {
      aspectRatio: 'var(--frame-n, 16) / var(--frame-d, 9)',
      overflow: 'hidden',
      display: 'flex',
      justifyContent: 'center',
      alignItems: 'center',
      '& > img, & > video': {
        inlineSize: '100%',
        blockSize: '100%',
        objectFit: 'cover',
      },
    },
  });

  // Reel Component
  addComponents({
    '.reel': {
      display: 'flex',
      blockSize: 'var(--reel-height, auto)',
      overflowX: 'auto',
      overflowY: 'hidden',
      '& > *': {
        flex: '0 0 var(--reel-item-width, auto)',
      },
      '& > * + *': {
        marginInlineStart: 'var(--reel-space, 1rem)',
      },
    },
    '.reel-no-bar': {
      scrollbarWidth: 'none',
      '&::-webkit-scrollbar': {
        display: 'none',
      },
    },
  });

  // Imposter Component
  addComponents({
    '.imposter': {
      position: 'var(--imposter-position, absolute)',
      insetBlockStart: '50%',
      insetInlineStart: '50%',
      transform: 'translate(-50%, -50%)',
    },
    '.imposter-contain': {
      overflow: 'auto',
      maxInlineSize: 'calc(100% - (var(--imposter-margin, 0px) * 2))',
      maxBlockSize: 'calc(100% - (var(--imposter-margin, 0px) * 2))',
    },
    '.imposter-fixed': {
      '--imposter-position': 'fixed',
    },
  });

  // Icon Component
  addComponents({
    '.icon': {
      height: '0.75em',
      width: '0.75em',
      '@supports (height: 1cap)': {
        height: '1cap',
        width: '1cap',
      },
    },
    '.with-icon': {
      display: 'inline-flex',
      alignItems: 'baseline',
      '& .icon': {
        marginInlineEnd: 'var(--icon-space, 0.5em)',
      },
    },
  });

  // Container Component (for container queries)
  addComponents({
    '.el-container': {
      containerType: 'inline-size',
    },
  });

  // Utility classes for custom properties
  addUtilities({
    '.stack-space-xs': { '--stack-space': '0.25rem' },
    '.stack-space-sm': { '--stack-space': '0.5rem' },
    '.stack-space-md': { '--stack-space': '1rem' },
    '.stack-space-lg': { '--stack-space': '1.5rem' },
    '.stack-space-xl': { '--stack-space': '2rem' },

    '.cluster-space-xs': { '--cluster-space': '0.25rem' },
    '.cluster-space-sm': { '--cluster-space': '0.5rem' },
    '.cluster-space-md': { '--cluster-space': '1rem' },
    '.cluster-space-lg': { '--cluster-space': '1.5rem' },
    '.cluster-space-xl': { '--cluster-space': '2rem' },

    '.grid-min-xs': { '--grid-min': '10rem' },
    '.grid-min-sm': { '--grid-min': '15rem' },
    '.grid-min-md': { '--grid-min': '20rem' },
    '.grid-min-lg': { '--grid-min': '25rem' },
    '.grid-min-xl': { '--grid-min': '30rem' },
  });

}, {
  theme: {
    extend: {
      // Extend spacing scale with modular scale
      spacing: {
        's-2': 'calc(1rem / 1.5 / 1.5)',
        's-1': 'calc(1rem / 1.5)',
        's0': '1rem',
        's1': 'calc(1rem * 1.5)',
        's2': 'calc(1rem * 1.5 * 1.5)',
        's3': 'calc(1rem * 1.5 * 1.5 * 1.5)',
      },
    },
  },
});
```

## tokens.js

```javascript
/**
 * Every Layout - Tailwind Design Tokens
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

module.exports = {
  // Modular scale with ratio 1.5 (perfect fifth)
  scale: {
    ratio: 1.5,
    base: '1rem',
    steps: {
      '-5': 'calc(var(--s-4) / 1.5)',
      '-4': 'calc(var(--s-3) / 1.5)',
      '-3': 'calc(var(--s-2) / 1.5)',
      '-2': 'calc(var(--s-1) / 1.5)',
      '-1': 'calc(var(--s0) / 1.5)',
      '0': '1rem',
      '1': 'calc(var(--s0) * 1.5)',
      '2': 'calc(var(--s1) * 1.5)',
      '3': 'calc(var(--s2) * 1.5)',
      '4': 'calc(var(--s3) * 1.5)',
      '5': 'calc(var(--s4) * 1.5)',
    },
  },

  // Measure (optimal line length)
  measure: {
    narrow: '45ch',
    default: '60ch',
    wide: '75ch',
  },

  // Spacing presets using modular scale
  spacing: {
    xs: '0.296rem',   // s-2
    sm: '0.444rem',   // s-1
    md: '1rem',       // s0
    lg: '1.5rem',     // s1
    xl: '2.25rem',    // s2
    '2xl': '3.375rem', // s3
  },

  // Aspect ratios
  aspectRatios: {
    square: '1 / 1',
    video: '16 / 9',
    photo: '4 / 3',
    cinema: '21 / 9',
    portrait: '3 / 4',
  },

  // Threshold values for Switcher
  thresholds: {
    sm: '20rem',
    md: '30rem',
    lg: '40rem',
    xl: '50rem',
  },

  // Sidebar widths
  sidebarWidths: {
    narrow: '15rem',
    default: '20rem',
    wide: '25rem',
  },

  // Grid minimums
  gridMins: {
    sm: '10rem',
    md: '15rem',
    lg: '20rem',
    xl: '25rem',
  },

  // CSS custom properties for :root
  cssVariables: {
    '--ratio': '1.5',
    '--s-5': 'calc(var(--s-4) / var(--ratio))',
    '--s-4': 'calc(var(--s-3) / var(--ratio))',
    '--s-3': 'calc(var(--s-2) / var(--ratio))',
    '--s-2': 'calc(var(--s-1) / var(--ratio))',
    '--s-1': 'calc(var(--s0) / var(--ratio))',
    '--s0': '1rem',
    '--s1': 'calc(var(--s0) * var(--ratio))',
    '--s2': 'calc(var(--s1) * var(--ratio))',
    '--s3': 'calc(var(--s2) * var(--ratio))',
    '--s4': 'calc(var(--s3) * var(--ratio))',
    '--s5': 'calc(var(--s4) * var(--ratio))',
    '--measure': '60ch',
    '--color-dark': '#000',
    '--color-light': '#fff',
    '--border-thin': '1px',
    '--border-thick': '4px',
  },
};
```
