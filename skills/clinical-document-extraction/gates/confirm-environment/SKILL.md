---
name: confirm-environment
parent_skill: clinical-document-extraction
description: "Tier-1 gate micro-skill. Confirms connection, database, schema, stage, and file location with the user before any pipeline execution. Returns {db}, {schema}, {stage}, {warehouse}, {connection}, {file_count}."
tools: ["snowflake_sql_execute", "ask_user_question"]
---

# Gate: Confirm Environment

This gate micro-skill confirms all environment parameters with the user before any pipeline SQL executes. It covers GATE E1, GATE E2, and GATE E3 from the extraction pipeline.

**This skill MUST complete and return before any other extraction skill loads.**

## Inputs (from router)

The parent router may have already confirmed `{account}`, `{role}`, `{warehouse}`. If so, those values are passed in. If not, this gate confirms them fresh.

## Outputs (returned to caller)

| Parameter | Example | Description |
|-----------|---------|-------------|
| `{db}` | `HCLS_COCO_TEST_DB` | Confirmed target database |
| `{schema}` | `CLINICAL_DOCS_ACTIVATION` | Confirmed target schema |
| `{stage}` | `INTERNAL_CLINICAL_DOCS_STAGE` | Confirmed internal stage |
| `{warehouse}` | `DEMO_BUILD_WH` | Confirmed warehouse |
| `{connection}` | `demo_connection1` | Snowflake connection name |
| `{file_count}` | `12` | Number of source files on stage |

---

## 🛑 MANDATORY STOP — GATE E1: Environment Confirmation

If the parent router has NOT already confirmed the connection, run:
```sql
SELECT CURRENT_ACCOUNT() AS account, CURRENT_ROLE() AS role, CURRENT_WAREHOUSE() AS warehouse;
```

Use `ask_user_question` to confirm. Present detected account, role, and warehouse as defaults, **plus an explicit option to change the warehouse**. **DO NOT PROCEED** until the user confirms.

If the user wants a different warehouse:
```sql
SHOW WAREHOUSES;
```
Present available warehouses and let the user select.

---

## 🛑 MANDATORY STOP — GATE E2: Database, Schema & Stage Selection

Use `ask_user_question` to ask the user which database, schema, and stage to use. **Each value must be explicitly confirmed — DO NOT auto-select or bundle silently.**

**Recommend** defaults:
| Parameter | Default | Description |
|---|---|---|
| `{db}` | `HCLS_COCO_TEST_DB` | Target database |
| `{schema}` | `CLINICAL_DOCS_ACTIVATION` | Target schema |
| `{stage}` | `INTERNAL_CLINICAL_DOCS_STAGE` | Internal stage for source documents |

**DO NOT PROCEED** until the user explicitly confirms or provides their own values.

---

## 🛑 MANDATORY STOP — GATE E3: File Location

Use `ask_user_question` to ask where source files are located:

| Option | Description |
|--------|-------------|
| Already on Snowflake stage | Files are on `@{db}.{schema}.{stage}` |
| Local files to upload | Use `PUT` via `snowflake_sql_execute` (NEVER use `snow stage copy` — CLI connection differs) |
| Cloud storage (S3/Azure/GCS) | Create storage integration + external stage |
| External system (EHR/API/Kafka) | Invoke `openflow` skill for CDC connectors |

**DO NOT assume file location from prior context.**

### File Upload (Local files)

If uploading local files, use PUT via `snowflake_sql_execute` — **NEVER** `snow stage copy`:
```sql
PUT file:///path/to/file.pdf @{db}.{schema}.{stage} AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```
**CRITICAL**: `snow stage copy`, `snow sql -q`, and `snow sql -f` all use a different CLI connection/role that may not have access to the target database. Always use `snowflake_sql_execute` for file operations.

### Validate Files on Stage

Before querying DIRECTORY(), ensure it is enabled:
```sql
ALTER STAGE @{db}.{schema}.{stage} SET DIRECTORY = (ENABLE = TRUE);
ALTER STAGE @{db}.{schema}.{stage} REFRESH;
```

Then validate:
```sql
SELECT COUNT(*) AS file_count,
       SUM(SIZE) / (1024*1024) AS total_size_mb
FROM DIRECTORY(@{db}.{schema}.{stage})
WHERE RELATIVE_PATH LIKE '%.pdf' OR RELATIVE_PATH LIKE '%.png'
   OR RELATIVE_PATH LIKE '%.jpg' OR RELATIVE_PATH LIKE '%.docx'
   OR RELATIVE_PATH LIKE '%.txt' OR RELATIVE_PATH LIKE '%.tiff';
```

**Report**: "{file_count} files found on stage ({total_size_mb} MB)"

### File Type Validation

| Extension | AI_EXTRACT | AI_PARSE_DOCUMENT | Per-Call Limits | Notes |
|-----------|-----------|-------------------|----------------|-------|
| .pdf | Yes | Yes | AI_EXTRACT: 100MB/125pg, AI_PARSE: 50MB/500pg | Primary format. Auto-split in preprocess. |
| .png, .jpg, .tiff | Yes | Yes | 10MB per image | Scanned documents |
| .docx | Yes | Yes | Same as PDF | Typed clinical notes |
| .txt | Yes | Yes | Same as PDF | EHR text exports |

If non-PDF files detected, inform user of format-specific constraints.

---

## Config Deduplication Check (Automatic — No Gate)

Before proceeding, check for and clean duplicate config rows:

```sql
SELECT CONFIG_TYPE, DOC_TYPE, FIELD_NAME, COUNT(*) AS cnt
FROM {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG
GROUP BY CONFIG_TYPE, DOC_TYPE, FIELD_NAME
HAVING COUNT(*) > 1;
```

If duplicates found:
```sql
DELETE FROM {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG
WHERE ROWID NOT IN (
    SELECT MAX(ROWID)
    FROM {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG
    GROUP BY CONFIG_TYPE, DOC_TYPE, FIELD_NAME
);
```

Repeat for `DOC_CLASSIFICATION_METADATA_ROWS` and `DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT`.

**Report** dedup results.

---

## Setup Objects (If Needed)

If objects don't exist, run the DDL setup script:

```
scripts/dynamic_pipeline_setup.sql
-- Update SET V_DB / V_SCHEMA at top to match {db} / {schema}
```

**Execution approach:**
1. Read script file contents
2. Replace all `$V_DB`, `$V_SCHEMA`, `$V_WAREHOUSE` with confirmed values
3. Run each STEP section as a separate `snowflake_sql_execute` call
4. Then create the 6 pipeline stored procedures from `scripts/proc_*.sql` files:
   - Read each file, replace `{db}` / `{schema}` / `{stage}` tokens with confirmed values
   - Execute each via `snowflake_sql_execute` (they use `$$` delimiters — no escaping issues)
   - Files: `proc_preprocess_clinical_docs.sql`, `proc_classify_metadata.sql`, `proc_extract_type_specific.sql`, `proc_classify_aggregated.sql`, `proc_extract_with_ai_agg.sql`, `proc_parse_with_images.sql`

> See parent orchestrator's **Execution Notes** section for critical `IDENTIFIER()`, connection, and FQN constraints.

---

## Return

After all gates complete, return the confirmed parameters to the caller:

```
GATE COMPLETE: confirm-environment
  db: {db}
  schema: {schema}
  stage: {stage}
  warehouse: {warehouse}
  connection: {connection}
  file_count: {file_count}
```

**DO NOT proceed to document type selection or pipeline execution. Return to caller.**
