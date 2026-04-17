# Prompt: Archival Data Engine

## Purpose
Evaluate database schema design and content loader implementation against
the archival-data-engine skill.

## Prompt Template

```
Evaluate the following database schema and content loader for archival
data quality and Astro integration.

SCHEMA:
[Paste SQL schema or db/config.ts]

LOADER:
[Paste custom content loader code]

CONTENT CONFIG:
[Paste content.config.ts collection definitions]

EVALUATION REQUIREMENTS:
1. Check Schema Design:
   - Normalized tables (no data duplication)
   - Foreign keys defined and enforced
   - Slug column for public URLs (not exposing database IDs)
   - Dates stored as ISO 8601 TEXT
   - CHECK constraints on enumerated fields
   - Indexes on commonly queried columns

2. Check Content Loader:
   - Opens database in readonly mode
   - Closes database connection in finally block
   - Uses generateDigest for incremental builds
   - Clears store before populating
   - Logs entry count
   - ID column correctly mapped

3. Check Zod Schema:
   - All fields validated with appropriate types
   - Nullable fields use z.nullable() not z.optional()
   - Date strings validated with regex or z.coerce.date()
   - Enums use z.enum() with controlled vocabulary

4. Check Data Integrity:
   - Sources/provenance tracked
   - No orphaned foreign keys
   - Credit roles use controlled vocabulary
   - Works have slugs (not just numeric IDs)

5. Check Integration:
   - Loader output matches Zod schema
   - Collection queries use proper filtering
   - Pages use getStaticPaths with slug params

OUTPUT FORMAT:
## Data Quality Score: X/10

## Findings
[List each finding with severity and fix]

## Schema Analysis
| Table | Rows | Issues |
|-------|------|--------|
| ... | ... | ... |

## Loader Analysis
| Check | Pass/Fail | Notes |
|-------|-----------|-------|
| Readonly mode | ... | ... |
| Connection cleanup | ... | ... |
| Digest generation | ... | ... |
| Error handling | ... | ... |
```

## Scoring (0-10)

| Range | Grade | Interpretation |
|-------|-------|----------------|
| 9-10 | A | Archival-grade data handling |
| 7-8 | B | Good, minor improvements needed |
| 5-6 | C | Adequate, data quality gaps |
| 3-4 | D | Below standard, integrity risks |
| 0-2 | F | Significant data quality issues |

## Verification Checklist

- [ ] Foreign keys enabled (PRAGMA foreign_keys = ON)
- [ ] All tables have primary keys
- [ ] Slug columns present for URL-facing entities
- [ ] Dates in ISO 8601 format
- [ ] Loader uses readonly mode
- [ ] Loader closes database in finally block
- [ ] Zod schema validates all fields
- [ ] Sources table exists for provenance
