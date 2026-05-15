---
name: clinical-docs-search
parent_skill: hcls-provider-cdata-clinical-docs
description: "Create and query a Cortex Search Service over parsed clinical document content. Enables full-text semantic search across discharge summaries, pathology reports, radiology reports, and other clinical documents."
tools: ["snowflake_sql_execute"]
---

# Clinical Documents Search

Creates a Cortex Search Service over the `CLINICAL_DOCUMENTS_RAW_CONTENT` table for full-text semantic search across parsed clinical documents.

## ⛔ MANDATORY INTERACTIVE PROTOCOL

**This skill enforces the Recommend → Confirm → Execute pattern. Every 🛑 MANDATORY STOP requires explicit user confirmation via `ask_user_question` before proceeding. Never skip a stop due to prior context or assumptions. See the parent router SKILL.md for full enforcement rules.**

| Gate | Step | What to Ask |
|------|------|-------------|
| GATE S1 | Step 1 | Warehouse, target lag, and confirmation to create search service |
| GATE S2 | Step 2 | What to search for (test query) |

---

## Prerequisites

- Pipeline must have processed documents (RAW_CONTENT table populated)
- Run the extraction pipeline first via `clinical-document-extraction` sub-skill

## Step 0: Query Data Model Knowledge (Auto — Injected by Router)

The clinical-docs router automatically runs this step before loading this skill. The search results from `CLINICAL_DOCS_MODEL_SEARCH_SVC` provide the current schema context.

**Query searchable columns and content structure:**
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "RAW_CONTENT searchable columns page content classification patient", "columns": ["table_name", "column_name", "data_type", "description", "contains_phi"]}'
);
```

**Use the results to:**
- Determine which columns to include in the Cortex Search Service `ATTRIBUTES` clause
- Identify PHI-containing columns that need search filtering awareness
- Validate `DOCUMENT_CLASSIFICATION` values match configured doc types
- Ground search filter examples in actual column names

**If search service is unavailable**, fall back to the hardcoded column list below (Step 1).

## Step 1: Create Cortex Search Service

### 🛑 MANDATORY STOP — GATE S1: Search Service Configuration

Use `ask_user_question` to ask the user: "Which warehouse should I use for the search service? What target lag is acceptable?" **DO NOT create the search service until the user confirms warehouse and target lag.**

**Recommend**: Warehouse from parent router `{warehouse}`, target lag `1 hour`.

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE {db}.{schema}.CLINICAL_DOCS_SEARCH_SERVICE
    ON PAGE_CONTENT
    ATTRIBUTES PATIENT_NAME, MRN, DOCUMENT_RELATIVE_PATH, DOCUMENT_CLASSIFICATION
    WAREHOUSE = {warehouse}
    TARGET_LAG = '{target_lag}'
    COMMENT = 'Search service for clinical document content'
    AS (
        SELECT
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PAGE_NUMBER_IN_PARENT,
            DOCUMENT_CLASSIFICATION,
            PATIENT_NAME, MRN, PAGE_CONTENT, DOC_TOTAL_PAGES,
            PRESIGNED_URL, STAGE_FILE_URL
        FROM {db}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT
    );
```

## Step 2: Test Search

### 🛑 MANDATORY STOP — GATE S2: Test Search Query

Use `ask_user_question` to ask: "What would you like to search for in the clinical documents?" **DO NOT run a test query without user input.**

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.{schema}.CLINICAL_DOCS_SEARCH_SERVICE',
    '{"query": "{user_query}", "columns": ["DOCUMENT_RELATIVE_PATH", "PAGE_CONTENT", "PATIENT_NAME", "MRN"], "limit": 5}'
);
```

## Search Patterns

### Search by content
```sql
'{"query": "discharge instructions post-operative care", "columns": ["DOCUMENT_RELATIVE_PATH", "PAGE_CONTENT", "PATIENT_NAME"]}'
```

### Filter by patient
```sql
'{"query": "findings impression", "filter": {"@eq": {"PATIENT_NAME": "SMITH, JOHN"}}, "columns": ["PAGE_CONTENT", "DOCUMENT_RELATIVE_PATH"]}'
```

### Filter by MRN
```sql
'{"query": "diagnosis", "filter": {"@eq": {"MRN": "12345"}}, "columns": ["PAGE_CONTENT", "DOCUMENT_RELATIVE_PATH"]}'
```

### Filter by document type
```sql
'{"query": "diagnosis findings", "filter": {"@eq": {"DOCUMENT_CLASSIFICATION": "DISCHARGE SUMMARY"}}, "columns": ["PAGE_CONTENT", "DOCUMENT_RELATIVE_PATH", "PATIENT_NAME"]}'
```
