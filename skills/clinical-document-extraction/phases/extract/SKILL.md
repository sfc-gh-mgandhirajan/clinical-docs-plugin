---
name: phase-extract
parent_skill: clinical-document-extraction
description: "Tier-2 phase skill. Executes type-specific field extraction with inline reactive gate E10 (extraction quality per type). Returns extraction counts."
tools: ["snowflake_sql_execute", "ask_user_question"]
---

# Phase: Extract

This phase skill executes type-specific field extraction from classified documents. It contains reactive gate E10 that fires after test extraction results are returned.

**The router MUST present this phase's results to the user before loading the next phase.**

## Inputs (from completed gates and prior phases)

| Parameter | Source |
|-----------|--------|
| `{db}`, `{schema}`, `{stage}`, `{warehouse}` | confirm-environment |
| `{configured_types}` | confirm-doc-types |
| `{warehouse_size_decision}` | confirm-pipeline-config |
| `{classification_distribution}` | phase-classify |

## Outputs (returned to caller)

| Parameter | Description |
|-----------|-------------|
| `{extraction_count}` | Total documents extracted |
| `{fields_per_type}` | Field count successfully extracted per type |

---

## Step 1: Single-Document Quality Gate Per Type

If `{warehouse_size_decision}` = auto-resize:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = '3XLARGE';
```

### 🛑 MANDATORY STOP — GATE E10: Extraction Quality Gate

**Test before batch**: Extract ONE document per classification type, display results, confirm field quality.

For each document classification found in the classify phase:

```sql
SELECT AI_EXTRACT(
    file => TO_FILE('@{db}.{schema}.{stage}', '{sample_file_for_type}'),
    responseFormat => {db}.{schema}.BUILD_DOC_TYPE_EXTRACTION_JSON('{DOC_TYPE}')
) AS test_result;
```

**Report** test result per doc type. Show field-by-field extraction output.

Use `ask_user_question` to ask: "Here are the extracted fields for one [{DOC_TYPE}] document. Are the results accurate? Shall I proceed to extract all [{DOC_TYPE}] documents?"

**DO NOT proceed to batch extraction without explicit approval per doc type.**

- **Yes** → proceed to batch for this type
- **No** → return to caller with `extraction_rejected: true` so the router can reload the confirm-doc-types gate for field refinement, then re-enter this phase

---

## Step 2: Batch Extraction

```sql
CALL {db}.{schema}.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES();
```

The UDF `BUILD_DOC_TYPE_EXTRACTION_JSON(DOC_TYPE)` builds per-type extraction schema:
```sql
SELECT OBJECT_AGG(FIELD_NAME, TO_VARIANT(EXTRACTION_QUESTION))
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG
WHERE DOCUMENT_CLASSIFICATION ILIKE DOC_TYPE AND IS_ACTIVE = TRUE;
```

**Report** extraction results per doc type:
```sql
SELECT DOCUMENT_CLASSIFICATION, COUNT(DISTINCT DOCUMENT_RELATIVE_PATH) AS doc_count, COUNT(DISTINCT FIELD_NAME) AS field_count
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
GROUP BY DOCUMENT_CLASSIFICATION;
```

If `{mode}` = step-by-step, use `ask_user_question`: "Extraction quality acceptable? Continue to document parsing?"

### PIVOT Column Quoting Reminder
Extraction results feed into pivot views. When pivot views are later created:
- Snowflake PIVOT creates columns with literal single quotes: `'MRN'`, `'PATIENT_NAME'`
- Reference them as `"'MRN'"` (double-quoted with embedded single quotes)
- **WRONG**: `"MRN"` or `MRN` → causes `invalid identifier 'MRN'`

---

## Return

```
PHASE COMPLETE: extract
  extraction_count: {total_docs}
  fields_per_type:
    DISCHARGE_SUMMARY: {N} fields x {M} docs
    PATHOLOGY_REPORT: {N} fields x {M} docs
    ...
  extraction_rejected: false
```

**STOP HERE. Return to caller. DO NOT proceed to parsing.**
