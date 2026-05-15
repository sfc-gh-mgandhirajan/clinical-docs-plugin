---
name: phase-parse-and-refresh
parent_skill: clinical-document-extraction
description: "Tier-2 phase skill. Executes document parsing (AI_PARSE_DOCUMENT), AI_AGG aggregation for split documents, AI-ready content layer refresh, Semantic View creation, and pipeline verification. No reactive gates — all decisions were made in prior phases."
tools: ["snowflake_sql_execute"]
---

# Phase: Parse and Refresh

This phase skill executes document parsing, aggregation, content layer refresh, Semantic View creation, and pipeline verification. There are no reactive gates in this phase — all data decisions were made in the classify and extract phases.

## Inputs (from completed gates and prior phases)

| Parameter | Source |
|-----------|--------|
| `{db}`, `{schema}`, `{stage}`, `{warehouse}` | confirm-environment |
| `{warehouse_size_decision}` | confirm-pipeline-config |
| `{classification_distribution}` | phase-classify |
| `{extraction_count}` | phase-extract |

## Outputs (returned to caller)

| Parameter | Description |
|-----------|-------------|
| `{pages_parsed}` | Total pages parsed |
| `{raw_content_rows}` | Rows in CLINICAL_DOCUMENTS_RAW_CONTENT |
| `{sv_created}` | Whether Semantic View was created |
| `{pipeline_summary}` | Full pipeline summary |

---

## Step 1: Parse Documents (AI_PARSE_DOCUMENT)

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = '3XLARGE';
```

```sql
CALL {db}.{schema}.CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2();
```

Parsing mode selection logic:
- `complex_tables_flag = YES` → `mode: LAYOUT`
- `image_flag = YES` → `mode: LAYOUT, extract_images: true`
- Otherwise → `mode: OCR`

For documents with images, `INJECT_IMAGE_DESCRIPTIONS` UDF inserts AI-generated descriptions adjacent to image references in page content.

**Report**: "{N} pages parsed from {M} documents"

---

## Step 2: Classify Aggregated Documents (Split-doc AI_AGG)

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = 'XLARGE';
```

For documents that were split in preprocessing:
```sql
CALL {db}.{schema}.CLASSIFY_AGGREGATED_DOCUMENTS();
```

Uses `AI_AGG` to classify across all pages of a split document.

---

## Step 3: Extract Aggregated Values (Split-doc AI_AGG)

```sql
CALL {db}.{schema}.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG();
```

Iterates through each document classification, builds extraction prompt via `LISTAGG`, runs `AI_AGG` over page content.

---

## Step 4: Refresh AI-Ready Content Layer

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = 'MEDIUM';
```

**IMPORTANT**: Before running the refresh, verify prerequisite data exists:

```sql
SELECT 'parse_output' AS source, COUNT(*) AS rows FROM {db}.{schema}.DOCS_PARSE_OUTPUT
UNION ALL
SELECT 'classifications', COUNT(*) FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
UNION ALL
SELECT 'extractions', COUNT(*) FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT;
```

If any returns 0, **WARN** the user and skip that data source rather than consuming the stream with empty results.

### Option A: Direct INSERT (Recommended for initial load)

```sql
INSERT INTO {db}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT (
    DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PAGE_NUMBER_IN_PARENT,
    DOCUMENT_CLASSIFICATION, PATIENT_NAME, MRN, PAGE_CONTENT,
    DOC_TOTAL_PAGES, PRESIGNED_URL, STAGE_FILE_URL, URL_GENERATED_AT
)
-- Non-split documents
SELECT
    s.DOCUMENT_RELATIVE_PATH, s.DOCUMENT_STAGE, s.PAGE_NUMBER_IN_PARENT,
    dcm_cls.FIELD_VALUE AS DOCUMENT_CLASSIFICATION,
    {coalesce_patient_fields} AS PATIENT_NAME,
    {coalesce_mrn_fields} AS MRN,
    CONCAT('[Page ', s.PAGE_NUMBER_IN_PARENT, ']' || CHR(10) || CHR(10), s.PAGE_CONTENT),
    s.DOC_TOTAL_PAGES,
    GET_PRESIGNED_URL(@{db}.{schema}.{stage}, s.DOCUMENT_RELATIVE_PATH, 604800),
    CONCAT('snow://stage/', REPLACE(s.DOCUMENT_STAGE, '@', ''), '/', s.DOCUMENT_RELATIVE_PATH),
    CURRENT_TIMESTAMP()
FROM {db}.{schema}.DOCS_PARSE_OUTPUT s
LEFT JOIN {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm_cls
    ON s.DOCUMENT_RELATIVE_PATH = dcm_cls.DOCUMENT_RELATIVE_PATH
    AND dcm_cls.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
{join_pivot_views_non_split}
WHERE s.PARENT_DOCUMENT_RELATIVE_PATH IS NULL
UNION ALL
-- Split documents (join via DOCUMENT_HIERARCHY)
SELECT
    s.PARENT_DOCUMENT_RELATIVE_PATH, dh.PARENT_DOCUMENT_STAGE, s.PAGE_NUMBER_IN_PARENT,
    dcm_cls.FIELD_VALUE, {coalesce_patient_fields}, {coalesce_mrn_fields},
    CONCAT('[Page ', s.PAGE_NUMBER_IN_PARENT, ']' || CHR(10) || CHR(10), s.PAGE_CONTENT),
    s.DOC_TOTAL_PAGES,
    GET_PRESIGNED_URL(@{db}.{schema}.{stage}, s.PARENT_DOCUMENT_RELATIVE_PATH, 604800),
    CONCAT('snow://stage/', REPLACE(dh.PARENT_DOCUMENT_STAGE, '@', ''), '/', s.PARENT_DOCUMENT_RELATIVE_PATH),
    CURRENT_TIMESTAMP()
FROM {db}.{schema}.DOCS_PARSE_OUTPUT s
JOIN {db}.{schema}.DOCUMENT_HIERARCHY dh
    ON s.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
LEFT JOIN {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm_cls
    ON s.PARENT_DOCUMENT_RELATIVE_PATH = dcm_cls.DOCUMENT_RELATIVE_PATH
    AND dcm_cls.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
{join_pivot_views_split}
WHERE s.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL;
```

### Option B: Task execution (incremental updates only)

```sql
EXECUTE TASK {db}.{schema}.REFRESH_RAW_CONTENT_TASK;
```

### Stream Recovery

If the stream is consumed but RAW_CONTENT is empty:
1. Stream data is **permanently lost** (consume-once)
2. Use Option A above to populate RAW_CONTENT
3. Recreate stream: `CREATE OR REPLACE STREAM {db}.{schema}.DOCS_PARSE_OUTPUT_STREAM ON TABLE {db}.{schema}.DOCS_PARSE_OUTPUT;`

---

## Step 5: Create Semantic View (Post-Data)

The Semantic View **cannot be created until pivot views contain data**.

```sql
-- Verify pivot views have data
SELECT COUNT(*) FROM {db}.{schema}.DISCHARGE_SUMMARY_V;
```

**CRITICAL**: `GENERATE_DYNAMIC_OBJECTS()` stored procedure **CANNOT** be created via `snowflake_sql_execute` — two patterns in the `$$` body are incompatible (Constraints #16: `EXECUTE IMMEDIATE...INTO :var` → `unexpected 'INTO'`, and #17: `IDENTIFIER(var||'...')` → `unexpected 'v_fqn'`). **DO NOT attempt to CREATE the procedure.** Instead, execute each step from the proc body individually:

1. **Step 0**: Deduplicate config table
2. **Steps 1-2b**: Seed classification + extraction configs from master config
3. **Step 3**: Create pivot views (see PIVOT Quoting below)
4. **Step 4**: Create MRN_PATIENT_MAPPING view
5. **Step 5**: Create REFRESH_RAW_CONTENT_TASK
6. **Step 6**: Create Semantic View (see Semantic View Syntax below)
7. **Steps 7-7b**: Refresh CKE tables

Use `dynamic_pipeline_setup.sql` Steps 0-7b as templates. Replace `:v_fqn` with `'{db}.{schema}'`.

### PIVOT Column Quoting (CRITICAL)
When creating pivot views manually (not via GENERATE_DYNAMIC_OBJECTS):
- Snowflake PIVOT creates columns with literal single quotes: `'MRN'`, `'PATIENT_NAME'`
- Reference them as `"'MRN'"` (double-quoted with embedded single quotes)
- Example: `"'MRN'" AS MRN, UPPER("'PATIENT_NAME'") AS PATIENT_NAME`
- **WRONG**: `"MRN"` or `MRN` → causes `invalid identifier 'MRN'`

### Semantic View Syntax (CRITICAL)
DIMENSIONS use `TABLE.DIMENSION_NAME AS ACTUAL_COLUMN_NAME` (dimension name first, NOT the column!):
- **CORRECT**: `DISCHARGE_SUMMARY_V.DS_MRN AS MRN`
- **WRONG**: `DISCHARGE_SUMMARY_V.MRN AS DS_MRN`

METRICS use `TABLE.METRIC_NAME AS AGGREGATE_EXPRESSION`:
- Example: `DISCHARGE_SUMMARY_V.PAT_CNT AS COUNT(DISTINCT MRN)`

---

## Step 6: Verify Results

```sql
SELECT 'Documents' AS metric, COUNT(DISTINCT DOCUMENT_RELATIVE_PATH) AS value FROM {db}.{schema}.DOCUMENT_HIERARCHY
UNION ALL
SELECT 'Pages Parsed', COUNT(*) FROM {db}.{schema}.DOCS_PARSE_OUTPUT
UNION ALL
SELECT 'Classifications', COUNT(DISTINCT DOCUMENT_RELATIVE_PATH) FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
UNION ALL
SELECT 'Extractions', COUNT(*) FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
UNION ALL
SELECT 'AI-Ready Pages', COUNT(*) FROM {db}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT;
```

Sample extracted data:
```sql
SELECT DOCUMENT_CLASSIFICATION, FIELD_NAME, FIELD_VALUE
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
ORDER BY DOCUMENT_RELATIVE_PATH, DOCUMENT_CLASSIFICATION, FIELD_NAME
LIMIT 20;
```

---

## Restore Warehouse (if auto-resize)

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = '{original_size}';
```

---

## Return

```
PHASE COMPLETE: parse-and-refresh
  pages_parsed: {N}
  raw_content_rows: {M}
  sv_created: {true|false}
  pipeline_summary:
    Documents: {doc_count}
    Pages Parsed: {page_count}
    Classifications: {class_count}
    Extractions: {extract_count}
    AI-Ready Pages: {raw_count}
```

**STOP HERE. Return to caller for "What next?" routing.**
