---
name: phase-classify
parent_skill: clinical-document-extraction
description: "Tier-2 phase skill. Executes preprocessing and classification with inline reactive gates E8 (classification quality) and E9 (unknown type detection). Returns classification distribution."
tools: ["snowflake_sql_execute", "ask_user_question"]
---

# Phase: Classify

This phase skill executes document preprocessing and classification. It contains reactive gates E8 and E9 that fire after classification data is returned.

**The router MUST present this phase's results to the user before loading the next phase.**

## Inputs (from completed gates)

| Parameter | Source |
|-----------|--------|
| `{db}`, `{schema}`, `{stage}`, `{warehouse}` | confirm-environment |
| `{configured_types}` | confirm-doc-types |
| `{mode}`, `{warehouse_size_decision}` | confirm-pipeline-config |

## Outputs (returned to caller)

| Parameter | Description |
|-----------|-------------|
| `{classification_distribution}` | Count of documents per classification type |
| `{unknown_types_handled}` | How unknown types were resolved (configured/skipped/none) |
| `{preprocessed_count}` | Number of files preprocessed |

---

## Step 1: Preprocess (Split Large Documents)

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = 'MEDIUM';
```

```sql
CALL {db}.{schema}.PREPROCESS_CLINICAL_DOCS(
    FILE_NAME => NULL,
    STAGE_NAME => '@{db}.{schema}.{stage}',
    OUTPUT_STAGE => '@{db}.{schema}.{stage}/processed',
    MAX_PAGES_PER_CHUNK => 125,
    MAX_SIZE_MB_PER_CHUNK => 100
);
```

**Report**: "{N} files processed, {M} split into chunks, {K} skipped (already processed)"

If `{mode}` = step-by-step, use `ask_user_question`: "Review preprocessing results? Continue to classification?"

---

## Step 2: Classify Documents (AI_PARSE_DOCUMENT + AI_COMPLETE)

**Why two-step?** `AI_EXTRACT` for classification was unreliable — it returned the same type for all documents. The two-step approach (parse first, then classify with AI_COMPLETE) produces accurate per-document classifications.

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = '3XLARGE';
```

### 🛑 MANDATORY STOP — GATE E8: Classification Quality Gate

**Test before batch**: Classify ONE document first using the two-step approach, display results, confirm quality.

```sql
-- Step 1: Parse the document to get text
SET test_text = (
    SELECT AI_PARSE_DOCUMENT(
        TO_FILE('@{db}.{schema}.{stage}', '{first_file_path}'),
        {'mode': 'OCR'}
    ):content::VARCHAR
);

-- Step 2: Classify using AI_COMPLETE with parsed text
SELECT AI_COMPLETE(
    'llama3.1-70b',
    CONCAT(
        'You are a clinical document classifier. Classify the following document and respond with ONLY a JSON object containing: DOCUMENT_CLASSIFICATION (one of: ',
        (SELECT LISTAGG(DISTINCT DOC_TYPE, ', ') FROM {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG WHERE CONFIG_TYPE = 'EXTRACTION'),
        ', OTHER), COMPLEX_TABLES_FLAG (YES/NO), IMAGE_FLAG (YES/NO).\n\nDocument text:\n',
        LEFT($test_text, 50000)
    )
) AS test_result;
```

**Report** the classification output for this single document.

Use `ask_user_question` to ask: "Here is the classification result for one sample document. Does this look correct? Shall I proceed to classify all documents?"
- **Yes** → proceed to batch
- **No** → review config fields in `DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG`, adjust, re-test

**DO NOT proceed to batch classification without explicit approval.**

### Batch Classification

```sql
CALL {db}.{schema}.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA();
```

Note: The procedure internally calls `AI_PARSE_DOCUMENT` (OCR) then `AI_COMPLETE` for each document. An optional `MODEL_NAME` parameter (default: `'llama3.1-70b'`) can be overridden:
```sql
CALL {db}.{schema}.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA(MODEL_NAME => 'claude-3-5-sonnet');
```

**Report** classification distribution:
```sql
SELECT FIELD_VALUE AS CLASSIFICATION, COUNT(*) AS DOC_COUNT
FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
GROUP BY FIELD_VALUE;
```

### Post-Classification Normalization (CRITICAL)
AI models return classifications with underscores (e.g., `DISCHARGE_SUMMARY`) but the config table uses spaces (e.g., `DISCHARGE SUMMARY`). **Always normalize immediately after classification:**
```sql
UPDATE {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
SET FIELD_VALUE = REPLACE(FIELD_VALUE, '_', ' ')
WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION' AND FIELD_VALUE LIKE '%\_%' ESCAPE '\';
```

---

## Step 2b: Classify Split (Aggregated) Documents

If preprocessing created split documents, their parent documents are NOT classified by the step above. Check and handle:

```sql
SELECT COUNT(DISTINCT dh.DOCUMENT_RELATIVE_PATH) AS unclassified_parents
FROM {db}.{schema}.DOCUMENT_HIERARCHY dh
WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NULL
  AND EXISTS (
      SELECT 1 FROM {db}.{schema}.DOCUMENT_HIERARCHY child
      WHERE child.PARENT_DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
  )
  AND NOT EXISTS (
      SELECT 1 FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
      WHERE dcm.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
        AND dcm.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
  );
```

If count > 0, parse split docs first, then classify via AI_AGG:
```sql
CALL {db}.{schema}.CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2();
CALL {db}.{schema}.CLASSIFY_AGGREGATED_DOCUMENTS();
```

Then normalize the aggregated classifications too:
```sql
UPDATE {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
SET FIELD_VALUE = REPLACE(FIELD_VALUE, '_', ' ')
WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION' AND FIELD_VALUE LIKE '%\_%' ESCAPE '\';
```

This ensures split document parents are classified BEFORE the extraction phase.

---

## Step 3: Unknown Type Detection

Check for documents classified as OTHER or unconfigured types:

```sql
SELECT dcm.FIELD_VALUE AS CLASSIFICATION, COUNT(DISTINCT dcm.DOCUMENT_RELATIVE_PATH) AS DOC_COUNT
FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
WHERE dcm.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
  AND NOT EXISTS (
      SELECT 1 FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG cfg
      WHERE cfg.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND cfg.IS_ACTIVE = TRUE
  )
GROUP BY dcm.FIELD_VALUE;
```

If results are returned:

### 🛑 MANDATORY STOP — GATE E9: Unknown Type Decision

**Report**: "I found {N} document(s) classified as {types} with no extraction config. These documents will be parsed and searchable but will NOT have structured field extraction, PATIENT_NAME/MRN linkage, or Semantic View coverage."

Use `ask_user_question` to ask: "Would you like to configure extraction for any of these types?"

**DO NOT skip unknown type handling or auto-decide.**

- **Yes** → For each new type:
  1. Sample one document:
     ```sql
     SELECT DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE
     FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
     WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION' AND FIELD_VALUE ILIKE '{new_type}'
     LIMIT 1;
     ```
  2. Auto-detect fields:
     ```sql
     SELECT AI_EXTRACT(
         file => TO_FILE('{stage}', '{sample_path}'),
         responseFormat => OBJECT_CONSTRUCT(
             'DOCUMENT_TYPE', 'What type of clinical document is this?',
             'KEY_FIELDS', 'List the key structured fields as a comma-separated list'
         )
     );
     ```
  3. **Recommend** field config. **Confirm** with user via `ask_user_question`.
  4. INSERT into `CLINICAL_DOCS_EXTRACTION_CONFIG`
  5. `CALL {db}.{schema}.GENERATE_DYNAMIC_OBJECTS('{db}', '{schema}', '{warehouse}', '{stage}');`
  6. Re-classify previously-OTHER docs:
     ```sql
     DELETE FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
     WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION' AND FIELD_VALUE ILIKE 'OTHER';
     CALL {db}.{schema}.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA();
     ```
  7. Re-check distribution. Loop back if OTHER still exists.

- **No** → Acknowledge and proceed. **Warn**: "Documents classified as {types} will appear in search results but will have NULL PATIENT_NAME/MRN and no Semantic View coverage."

---

## Return

```
PHASE COMPLETE: classify
  preprocessed_count: {N}
  classification_distribution:
    DISCHARGE_SUMMARY: {count}
    PATHOLOGY_REPORT: {count}
    ...
  unknown_types_handled: {configured|skipped|none}
```

**STOP HERE. Return to caller. DO NOT proceed to extraction.**
