# Every Layout Constitution

Priority rules and conflict resolution for applying Every Layout principles.

---

## Priority Hierarchy

When principles or approaches conflict, resolve in this order:

### 1. Accessibility (Highest Priority)
- Screen reader support (ELP_015)
- Zoom compliance for fluid sizing (ELP_026)
- Motion safety (ELP_028)
- Focus visibility (ELP_029)
- Keyboard navigation
- Color contrast

### 2. Content Integrity
- Progressive enhancement (ELP_027)
- Measure constraint for readability (ELP_006)
- No content truncation without user control
- Logical properties for internationalization (ELP_004)

### 3. Intrinsic Behavior
- Intrinsic sizing over fixed dimensions (ELP_002)
- Algorithmic layouts over breakpoints (ELP_009)
- Fluid sizing via clamp (ELP_025)
- Browser delegation where possible (ELP_010)
- Native containment patterns (ELP_019, ELP_020)
- Subgrid alignment (ELP_021)

### 4. Composition
- Primitive composition over monolithic components (ELP_001)
- Child-only effects for predictability (ELP_008)

### 5. Consistency
- Modular scale spacing (ELP_005)
- Custom properties for configuration (ELP_011)

### 6. Visual Coherence (owned by css-design-system skill)

Visual-coherence principles (ELP_016–018 theme-aware color; ELP_022–023 shadows; ELP_024 icon sizing) are defined and ranked in `css-design-system/references/principles.md`. The two skills compose when both are active; layout-engine owns priorities 1–5, design-system owns priority 6.

---

## Conflict Resolution

### Principle vs. Principle

**ELP_002 (Intrinsic) vs. ELP_006 (Measure)**
- Resolution: Measure wins for text content
- Rationale: Readability is a form of content integrity
- Example: Use `max-inline-size: var(--measure)` even though it's "extrinsic"

**ELP_009 (Algorithmic) vs. ELP_013 (Container Queries)**
- Resolution: Try algorithmic first (ELP_014)
- Rationale: Simpler solutions are more robust
- If algorithmic fails: Container queries are acceptable
- If container queries fail: Media queries as last resort

**ELP_001 (Composition) vs. Performance**
- Resolution: Composition wins unless proven bottleneck
- Rationale: Extra DOM is rarely the performance problem
- Measure before optimizing

**ELP_017 (Surface Elevation) vs. ELP_022 (Shadows)**
- Resolution: Use both together in light mode; prefer lightness in dark mode
- Rationale: Shadows are less effective on dark backgrounds
- Both approaches can coexist with theme-aware selection

**ELP_028 (Motion Safety) vs. ELP_009 (Algorithmic Layout)**
- Resolution: Motion Safety wins; reduced-motion users get instant transitions
- Rationale: Accessibility is tier 1, algorithmic behavior is tier 3
- Algorithmic layouts should still function without animation

**ELP_029 (Focus Visibility) vs. Visual Design**
- Resolution: Focus Visibility wins; focus rings are non-negotiable
- Rationale: Keyboard users require visible indicators (WCAG 2.4.7)
- Custom focus indicators are acceptable if they provide equivalent visibility

**ELP_027 (Progressive Enhancement) vs. JS Framework Requirements**
- Resolution: Document the JS dependency explicitly when unavoidable
- Rationale: SPAs and framework contexts may require JS as baseline
- Still apply progressive enhancement within the JS layer where possible

### Primitive vs. Primitive

**ELC_SIDEBAR vs. ELC_SWITCHER**
- Use Sidebar when: One element has fixed/intrinsic width
- Use Switcher when: All elements should be equal width

**ELC_GRID vs. ELC_CLUSTER**
- Use Grid when: Items should have equal widths
- Use Cluster when: Items should have intrinsic widths

**ELC_STACK vs. Gap property**
- Use Stack when: You need the owl selector behavior
- Use Gap when: Simple flex/grid container is sufficient

---

## Non-Negotiables

These rules have no exceptions:

### 1. Always Cite IDs
Every primitive reference includes its ID:
- "Use Stack (ELC_STACK)"
- "This violates ELP_002"

### 2. Never Invent Primitives
Only use the 13 documented primitives. If none fit:
1. Re-examine if a combination works
2. Document why no primitive applies
3. Use vanilla CSS with principle compliance

### 3. Never Use Arbitrary Values
All values must come from:
- Modular scale (`--s-5` through `--s5`)
- Primitive parameters
- Documented tokens

**Forbidden**: `17px`, `1.3rem`, `23%`

### 4. Always Explain Tradeoffs
When recommending an approach, state:
- What benefit it provides
- What cost it incurs
- What alternatives were considered

### 5. Never Skip Traceability
Every recommendation traces to:
- A primitive ID (ELC_*)
- A principle ID (ELP_*)
- Or explicit acknowledgment that it's outside the system

---

## Decision Trees

### "Should I use a media query?"

```
Is the change based on viewport?
|-- No -> Don't use media query
+-- Yes -> Can intrinsic layout achieve this?
    |-- Yes -> Use Switcher/Sidebar/Grid instead
    +-- No -> Can container query achieve this?
        |-- Yes -> Use Container (ELC_CONTAINER)
        +-- No -> Media query is acceptable (document why)
```

### "Which spacing value should I use?"

```
What is the context?
|-- Between text elements -> --s1 (1.5rem)
|-- Tight inline spacing -> --s-1 (0.667rem)
|-- Section breaks -> --s2 or --s3
+-- Custom need -> Pick nearest scale value, never arbitrary
```

### "Should I add a wrapper div?"

```
Does composition require it?
|-- No -> Don't add
+-- Yes -> Is the nesting depth reasonable (<5 levels)?
    |-- Yes -> Add the wrapper (ELP_001 supports this)
    +-- No -> Reconsider the composition approach
```

---

## Code Review Checklist

Use this checklist when auditing layout code:

### Structure
- [ ] No fixed pixel widths on containers
- [ ] No media queries for layout switching (unless documented exception)
- [ ] Primitives are composed, not nested unnecessarily
- [ ] Child-only selectors used (>)

### Values
- [ ] All spacing from modular scale
- [ ] All sizing intrinsic or constrained (min/max)
- [ ] Custom properties used for configuration

### Properties
- [ ] Logical properties used (inline/block)
- [ ] box-sizing: border-box applied globally
- [ ] Gap preferred over margin in flex/grid

### Accessibility
- [ ] Icons have accessible labels
- [ ] Color not the only indicator
- [ ] Focus states visible via :focus-visible (ELP_029)
- [ ] Animations respect prefers-reduced-motion (ELP_028)
- [ ] Content readable without CSS/JS (ELP_027)

---

## Escalation Path

When you encounter a situation not covered by this constitution:

1. **Check references/principles.md** for relevant principle
2. **Consult the Chooser** in SKILL.md for primitive guidance
3. **Apply priority hierarchy** (accessibility first)
4. **Document the decision** with rationale
5. **Flag for future review** if pattern recurs
