# Prompt: Choose Primitive

## Purpose
Select the appropriate Every Layout primitive for a given layout problem.

## Fixtures

Run this prompt against each scenario in the scenario bank, then score the
selections:

| Fixture | Expected Score | Grade |
|---------|----------------|-------|
| `eval/fixtures/choose-primitive-scenarios.md` (13 scenarios) | 9-10/10 | A |

## Prompt Template

```
Help me choose the right Every Layout primitive.

LAYOUT REQUIREMENT:
[Describe the layout need]

CONTEXT:
- Container: [Description]
- Content type: [Text/images/cards/etc.]
- Responsive behavior needed: [Yes/No]
- Specific constraints: [Any requirements]

CONSTRAINTS:
1. Must use Every Layout primitives only
2. Cite primitive ID (ELC_*) in response
3. Explain why this primitive fits
4. Mention any alternatives considered

OUTPUT:
1. Primary recommendation with ELC_* ID
2. Code example
3. Why this primitive (not alternatives)
4. Configuration options
```

## Decision Tree

### Question 1: Is this about spacing between elements?
- **Vertical spacing** → ELC_STACK
- **Horizontal spacing with wrapping** → ELC_CLUSTER
- **Both directions** → Combine Stack + Cluster

### Question 2: Is this a two-element layout?
- **One fixed, one flexible** → ELC_SIDEBAR
- **Equal elements that switch** → ELC_SWITCHER

### Question 3: Is this a grid of items?
- **Equal columns, responsive** → ELC_GRID
- **Horizontal scrolling** → ELC_REEL

### Question 4: Is this about centering?
- **Horizontal centering with max-width** → ELC_CENTER
- **Vertical centering** → ELC_COVER
- **Overlay centering** → ELC_IMPOSTER

### Question 5: Is this about containing/constraining?
- **Aspect ratio** → ELC_FRAME
- **Padding/border** → ELC_BOX
- **Container queries** → ELC_CONTAINER

### Question 6: Is this about inline elements?
- **Icons with text** → ELC_ICON

## Expected Output Format

```
## Recommendation: [Primitive Name] (ELC_*)

### Why This Primitive
[Explanation of fit]

### Code Example
[HTML + CSS]

### Configuration
- `--property`: [description]

### Alternatives Considered
- [Other primitive]: [why not chosen]

### Verification
[How to test it works]
```

## Scoring (0-10)

Score a run against `eval/fixtures/choose-primitive-scenarios.md`:

| Dimension | Points | Criteria |
|-----------|--------|----------|
| Primitive correctness | 0-6 | The expected `ELC_*` is named for each scenario (≈0.5 per scenario across the 13, rounded to 6) |
| Alternatives reasoning | 0-2 | Correctly rules out each scenario's listed near-miss, with the right reason |
| Configuration & verification | 0-2 | Names the primitive's real custom properties and a valid way to test the result |
| **Total** | **/10** | |

A correct response scores **9-10/10 (A)**. Any scenario answered with a
non-existent or wrong-axis primitive (e.g. Cluster for vertical spacing) costs
full marks for that scenario.
