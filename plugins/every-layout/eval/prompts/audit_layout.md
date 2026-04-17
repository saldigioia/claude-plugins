# Prompt: Audit Layout

## Purpose
Evaluate CSS layout code against Every Layout principles.

## Fixtures

Run this prompt against these fixture files:

| Fixture | Expected Score | Grade |
|---------|---------------|-------|
| `eval/fixtures/anti-pattern-fixed-grid.html` | 3-6/24 | F |
| `eval/fixtures/anti-pattern-design-system.html` | 2-5/24 | F |
| `eval/fixtures/anti-pattern-motion.html` | varies | D-F |
| `eval/fixtures/anti-pattern-focus.html` | varies | D-F |
| `eval/fixtures/compliant-article.html` | 21-24/24 | A |

## Prompt Template

```
Audit the following CSS/HTML for Every Layout compliance.

CODE:
[Paste fixture file content here, or pass a file path for the agent to read]

AUDIT REQUIREMENTS:
1. Check against Each Principle:
   - ELP_001: Composition over inheritance
   - ELP_002: Intrinsic sizing over extrinsic
   - ELP_003: Universal border-box
   - ELP_004: Logical properties
   - ELP_005: Modular scale spacing
   - ELP_006: Measure constraint
   - ELP_009: Algorithmic self-governing layout
   - ELP_028: Motion safety (prefers-reduced-motion)
   - ELP_029: Focus visibility (:focus-visible)

2. Identify Anti-Patterns:
   - Fixed pixel widths on containers
   - Media queries for layout switching
   - Arbitrary spacing values
   - Physical directional properties
   - Animations without prefers-reduced-motion gate
   - outline: none without :focus-visible replacement
   - Scroll jacking / custom scroll overrides

3. Score using the rubric (0-24 scale, 8 dimensions)

4. Provide specific recommendations with:
   - Line numbers
   - Current code
   - Suggested replacement
   - Principle ID reference

OUTPUT FORMAT:
## Violations Found
[List each violation with line number and principle ID]

## Score: X/24

## Recommendations
[Specific code changes]

## Primitives That Could Help
[List relevant ELC_* primitives]
```

## Expected Output Structure

```json
{
  "violations": [
    {
      "line": 12,
      "code": "width: 300px",
      "principle": "ELP_002",
      "severity": "high",
      "fix": "max-inline-size: 20rem"
    }
  ],
  "score": {
    "intrinsic_sizing": 2,
    "responsive": 1,
    "composition": 2,
    "spacing": 2,
    "logical_properties": 1,
    "accessibility": 2,
    "motion_safety": 1,
    "focus_visibility": 2,
    "total": 13
  },
  "recommended_primitives": ["ELC_GRID", "ELC_STACK"]
}
```

## Verification Checklist

After audit, verify that:
- [ ] All violations cite specific principle IDs
- [ ] Score matches rubric criteria
- [ ] Recommendations are actionable
- [ ] Suggested primitives are appropriate
