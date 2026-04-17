# Prompt: Astro Site Architecture

## Purpose
Evaluate Astro site setup and architecture against the astro-site-architect skill.

## Prompt Template

```
Evaluate the following Astro project structure and code for compliance with
the Every Layout + Astro site architecture patterns.

PROJECT STRUCTURE:
[Paste directory listing]

KEY FILES:
[Paste astro.config.mjs, content.config.ts, Base layout, and a sample page]

EVALUATION REQUIREMENTS:
1. Check Project Structure:
   - content.config.ts at project root (not src/content/config.ts)
   - Layouts use Cover > Center > Stack spine
   - Components organized by concern (layout/, ui/, islands/)
   - Styles in src/styles/ (not public/)

2. Check Content Layer:
   - Collections defined with typed Zod schemas
   - Loaders appropriate for data source
   - No untyped data flowing through

3. Check Island Architecture:
   - No unnecessary client:* directives
   - Default is zero-JS static HTML
   - Each island has justified hydration

4. Check Layout Composition:
   - Base layout uses Cover > Center > Stack
   - Skip link present
   - Critical CSS inlined
   - Remaining CSS preloaded

5. Check Routing:
   - getStaticPaths for dynamic routes
   - Semantic, permanent URLs (no database IDs)
   - Proper 404 page

6. Check Performance:
   - Static output mode (output: 'static')
   - Images use astro:assets
   - Font loading uses font-display: optional

OUTPUT FORMAT:
## Architecture Score: X/10

## Findings
[List each finding with severity and specific recommendation]

## Compliance Summary
| Area | Status | Notes |
|------|--------|-------|
| Project Structure | Pass/Fail | ... |
| Content Layer | Pass/Fail | ... |
| Island Architecture | Pass/Fail | ... |
| Layout Composition | Pass/Fail | ... |
| Routing | Pass/Fail | ... |
| Performance | Pass/Fail | ... |
```

## Scoring (0-10)

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 9-10 | A | Exemplary Astro + Every Layout architecture |
| 7-8 | B | Good, minor improvements needed |
| 5-6 | C | Adequate, several areas need work |
| 3-4 | D | Below standard, significant issues |
| 0-2 | F | Does not follow recommended architecture |

## Verification Checklist

- [ ] content.config.ts at project root
- [ ] All collections have Zod schemas
- [ ] Base layout uses Cover > Center > Stack
- [ ] Skip link present in Base layout
- [ ] Critical CSS inlined in <head>
- [ ] No unjustified client:* directives
- [ ] Static output mode
- [ ] Semantic URLs in routing
- [ ] Images use astro:assets
