# Prompt: Refactor to Primitives

## Purpose
Evaluate the ability to transform non-compliant CSS layout code into Every Layout primitive-based implementations.

## Fixtures

Run this prompt against these fixture files:

| Fixture | Key Violations | Expected Primitives |
|---------|---------------|---------------------|
| `eval/fixtures/anti-pattern-fixed-grid.html` | Fixed widths, media queries, arbitrary spacing | ELC_GRID, ELC_STACK, ELC_FRAME, ELC_BOX |
| `eval/fixtures/anti-pattern-design-system.html` | No tokens, no motion safety, physical props | ELC_COVER, ELC_CENTER, ELC_STACK, ELC_BOX |

## Prompt Template

```
Refactor the following CSS/HTML to use Every Layout primitives.

CODE:
[Paste fixture file content here, or pass a file path to read]

REQUIREMENTS:
1. Identify all violations against Every Layout principles (cite ELP_* IDs)
2. Map each problematic pattern to its replacement primitive (cite ELC_* IDs)
3. Provide complete refactored code (HTML + CSS)
4. Use only documented primitives and modular scale values
5. Preserve visual appearance and functionality

OUTPUT FORMAT:

## Current State Analysis
- Layout patterns detected
- Violations found (with ELP_* IDs and line numbers)

## Primitive Mapping

| Current Pattern | Violation | Replacement | Primitive ID |
|-----------------|-----------|-------------|--------------|
| [code] | ELP_XXX | [primitive] | ELC_XXX |

## Refactored Code

### HTML
[complete refactored HTML]

### CSS
[complete refactored CSS using only primitives and scale values]

## Verification
- [ ] No fixed pixel widths on containers (ELP_002)
- [ ] No media queries for layout switching (ELP_009)
- [ ] All spacing from modular scale (ELP_005)
- [ ] Logical properties used throughout (ELP_004)
- [ ] Primitives compose correctly (ELP_001)
- [ ] prefers-reduced-motion respected (ELP_028)
- [ ] :focus-visible styled (ELP_029)

## Summary
Replaced [N] anti-patterns with [M] primitives.
Primitives used: [list with ELC_* IDs]
```

## Evaluation Criteria

### 1. Violation Detection (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Misses most violations, no principle IDs cited |
| 1 | Finds obvious violations (fixed widths), misses subtle ones |
| 2 | Finds most violations with correct ELP_* citations |
| 3 | Complete violation inventory with accurate line numbers and IDs |

### 2. Primitive Selection (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Wrong primitives selected or non-standard solutions used |
| 1 | Some correct selections, some inappropriate or missing |
| 2 | Mostly correct; minor suboptimal choices |
| 3 | Optimal primitive for every pattern, correct ELC_* IDs throughout |

### 3. Code Quality (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Refactored code still violates principles or is incomplete |
| 1 | Some violations fixed, new ones introduced or spacing arbitrary |
| 2 | Clean refactor; minor issues (e.g., one physical property remains) |
| 3 | Fully compliant: intrinsic, composable, scale-based, logical properties |

### 4. Completeness (0-3 points)

| Score | Criteria |
|-------|----------|
| 0 | Partial output, missing HTML or CSS, no verification |
| 1 | Code provided but mapping table or verification missing |
| 2 | All sections present; minor omissions in verification |
| 3 | Complete output: analysis, mapping, code, and full verification checklist |

## Total Score: 0-12

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 11-12 | A | Expert-level refactoring |
| 9-10 | B | Competent, minor improvements needed |
| 6-8 | C | Adequate, several areas need work |
| 3-5 | D | Below standard, significant gaps |
| 0-2 | F | Does not demonstrate refactoring ability |

## Expected Output Structure

```json
{
  "violations_found": [
    {
      "line": 5,
      "code": "width: 1200px",
      "principle": "ELP_002",
      "severity": "high"
    }
  ],
  "primitive_mapping": [
    {
      "current": "flex + media queries for columns",
      "replacement": "Grid",
      "id": "ELC_GRID",
      "rationale": "Responsive columns without breakpoints"
    }
  ],
  "score": {
    "violation_detection": 3,
    "primitive_selection": 3,
    "code_quality": 3,
    "completeness": 3,
    "total": 12
  }
}
```
