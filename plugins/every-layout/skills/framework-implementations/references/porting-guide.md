# Operator Prompt: Generate Component Port

## Purpose
Generate framework-specific implementations of Every Layout primitives.

## Prerequisites
- Load: `SKILLPACK.md`, `data/cards-primitives.json`
- Context: Target framework and primitive(s) to port

## Input Format
```
Generate a component port for:

PRIMITIVE(S):
- [ELC_XXX - Name]
- [ELC_YYY - Name] (optional additional primitives)

TARGET FRAMEWORK:
- [React / Vue / Svelte / Astro / Web Components / etc.]

REQUIREMENTS (optional):
- TypeScript support: [Yes/No]
- Styling approach: [CSS Modules / Styled Components / Tailwind / etc.]
- Additional props needed: [custom requirements]
```

## Output Format
```markdown
## Component Port: [Primitive Name] (ELC_XXX)

### Framework: [Target Framework]

### Component Specification

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `prop` | type | default | [from primitive parameters] |

### Implementation

#### [ComponentName].[ext]
```[language]
[complete component code]
```

#### Types (if TypeScript)
```typescript
[type definitions]
```

#### Styles (if separate)
```css
[CSS implementation]
```

### Usage Examples

#### Basic Usage
```[framework]
[minimal example]
```

#### With Configuration
```[framework]
[example with props]
```

#### Composition Example
```[framework]
[example combining with other primitives]
```

### Props Reference

#### `propName`
- **Type**: `type`
- **Default**: `value`
- **Description**: [from primitive card]
- **Example**: `<Component propName={value} />`

### Testing Checklist
- [ ] [verification_test 1 from primitive card]
- [ ] [verification_test 2]
- [ ] Props pass type checking
- [ ] Component renders without errors
- [ ] Styles match primitive specification

### Accessibility Notes
- [Any accessibility considerations from primitive]

### Related Components
- [Other primitives that compose well with this one]
```

## Constraints
- MUST match primitive card specification exactly
- MUST expose all parameters as configurable props
- MUST cite primitive ID (ELC_*) in all documentation
- MUST include usage examples
- MUST NOT add features not in the primitive spec
- MUST NOT use arbitrary values (use modular scale)

## Framework-Specific Guidelines

### React
```tsx
import { forwardRef, type HTMLAttributes, type ElementType } from 'react';

interface PrimitiveProps extends HTMLAttributes<HTMLElement> {
  as?: ElementType;
  // primitive-specific props
}

export const Primitive = forwardRef<HTMLElement, PrimitiveProps>(
  ({ as: Component = 'div', children, ...props }, ref) => {
    // implementation
  }
);

Primitive.displayName = 'Primitive';
```

### Vue 3
```vue
<script setup lang="ts">
interface Props {
  // primitive-specific props
}

withDefaults(defineProps<Props>(), {
  // defaults from primitive card
});
</script>

<template>
  <div class="primitive">
    <slot />
  </div>
</template>

<style scoped>
/* CSS from primitive card */
</style>
```

### Astro
```astro
---
interface Props {
  // primitive-specific props
}

const { prop = 'default' } = Astro.props;
---

<div class="primitive" style={`--prop: ${prop}`}>
  <slot />
</div>

<style>
/* CSS from primitive card */
</style>
```

### Web Components
```javascript
class EveryLayoutPrimitive extends HTMLElement {
  static get observedAttributes() {
    return ['prop'];
  }

  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
  }

  connectedCallback() {
    this.render();
  }

  attributeChangedCallback() {
    this.render();
  }

  render() {
    // implementation
  }
}

customElements.define('el-primitive', EveryLayoutPrimitive);
```

## CSS-to-Props Mapping

Map primitive CSS custom properties to component props:

| CSS Property | Prop Name | Type | Notes |
|--------------|-----------|------|-------|
| `--space` | `space` | string | CSS length value |
| `--measure` | `max` | string | CSS length value |
| `--min` | `min` | string | CSS length value |
| `--threshold` | `threshold` | string | CSS length value |

## Stop Condition
```
STOP — Component port complete.
Generated: [Component Name] for [Framework]
Primitive: ELC_XXX
Props: [list]
Ready for: Integration and testing
```
