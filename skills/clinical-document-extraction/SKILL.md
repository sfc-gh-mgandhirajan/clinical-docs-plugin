---
name: clinical-document-extraction
parent_skill: hcls-provider-cdata-clinical-docs
description: "Orchestrator for the clinical document extraction pipeline. Delegates to gate micro-skills (Tier 1) for pre-condition confirmation and phase skills (Tier 2) for pipeline execution. No inline gates or pipeline SQL — all execution is in sub-skills."
tools: ["snowflake_sql_execute"]
---

# Clinical Document Extraction — Orchestrator

An interactive, config-driven pipeline for extracting structured intelligence from clinical documents (PDF, DOCX, PNG, JPG, TIFF, TXT) using Snowflake Cortex AI functions (`AI_PARSE_DOCUMENT`, `AI_COMPLETE`, `AI_EXTRACT`, `AI_AGG`). Classification uses a two-step approach: `AI_PARSE_DOCUMENT` (OCR) → `AI_COMPLETE` for reliable per-document typing. Field extraction uses `AI_EXTRACT`.

## Platform Skill Synergy

This industry skill **delegates** to the bundled `document-intelligence` platform skill for generic document processing, while retaining domain-specific clinical logic.

| Capability | Delegated To | Our Addition |
|---|---|---|
| Pricing estimation | `document-intelligence` SKILL.md §"Always Display Pricing" | Clinical-specific cost projections by pipeline step |
| File location & upload | `document-intelligence` SKILL.md §Step 2 | Defaults to `INTERNAL_CLINICAL_DOCS_STAGE` |
| File type validation | `document-intelligence` SKILL.md §Step 3 | Clinical docs are predominantly PDF |
| Test-before-batch | `document-intelligence/references/extraction.md` §Step 5 | Single-doc quality gate before batch classification & extraction |
| Pipeline templates | `document-intelligence/references/pipeline.md` | Domain-specific task with MRN linkage, pivot view joins, presigned URLs |

**Domain-specific** (NOT delegated): Config-driven extraction schemas, classification routing, AI_AGG dual-path, adaptive parse mode, image description injection, identity linkage, pivot views, AI-ready content layer.

## Execution Flow

### Step 0: Query Data Model Knowledge (Auto — Injected by Router)

The clinical-docs router automatically runs this step before loading this skill. The search results from `CLINICAL_DOCS_MODEL_SEARCH_SVC` and `CLINICAL_DOCS_SPECS_SEARCH_SVC` provide the current schema and doc type specs.

**Query extraction config and doc type definitions:**
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_SEARCH_SVC',
    '{"query": "extraction fields for all document types", "columns": ["doc_type", "field_name", "extraction_question", "data_type", "contains_phi", "view_name"]}'
);
```

**Use the results to:**
- Validate configured doc types against the spec CKE (Gate E4-E5)
- Ground extraction prompts in the latest spec definitions
- Build config table INSERTs from spec CKE instead of hardcoded values
- Inform the OTHER onboarding loop (Gate E9) with similar doc type templates

**If search service is unavailable**, fall back to `references/document_type_specs.yaml` on disk.

### Pre-Conditions (Tier 1 Gates — must complete before any pipeline execution)

Each gate is a **separate skill load**. Gates complete sequentially and return confirmed parameters to the orchestrator.

| # | Gate Skill | Gates Covered | Returns |
|---|-----------|--------------|---------|
| 1 | **Load** `gates/confirm-environment/SKILL.md` | E1 + E2 + E3 | `{db}`, `{schema}`, `{stage}`, `{warehouse}`, `{connection}`, `{file_count}` |
| 2 | **Load** `gates/confirm-doc-types/SKILL.md` | E4 + E5 | `{configured_types}`, `{fields_per_type}` |
| 3 | **Load** `gates/confirm-pipeline-config/SKILL.md` | E6 + E6b + E7 | `{mode}`, `{warehouse_size_decision}`, `{estimated_cost}`, `{user_approved_cost}` |

### Pipeline Phases (Tier 2 — router re-enters between each)

Each phase is a **separate skill load**. The router MUST present phase results to the user and get confirmation before loading the next phase.

| # | Phase Skill | Steps Covered | Reactive Gates | Re-entry Question |
|---|------------|--------------|----------------|-------------------|
| 4 | **Load** `phases/classify/SKILL.md` | Preprocess + Classify | E8 (quality) + E9 (unknown type) | "Classification complete. Proceed to extraction?" |
| 5 | **Load** `phases/extract/SKILL.md` | Type-specific extraction | E10 (quality per type) | "Extraction complete. Proceed to parse?" |
| 6 | **Load** `phases/parse-and-refresh/SKILL.md` | Parse + AGG + Refresh + SV + Verify | None | "Pipeline complete! What next?" |

### Post-Pipeline

| # | Gate | Action |
|---|------|--------|
| 7 | GATE E11: What next? | Use `ask_user_question` to present: Search / Agent / Viewer / Add type / Governance / Share |

## Key Cortex AI Patterns

### Two-Step Classification (AI_PARSE_DOCUMENT + AI_COMPLETE)

**AI_EXTRACT was unreliable for classification** — it returned the same type for all documents. The pipeline uses a two-step approach:

```sql
-- Step 1: Parse to get text
AI_PARSE_DOCUMENT(TO_FILE(stage, path), {'mode': 'OCR'}):content::VARCHAR

-- Step 2: Classify with AI_COMPLETE
AI_COMPLETE('llama3.1-70b', classification_prompt || parsed_text)
```

The classification prompt is built dynamically from `DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG` (seeded from `CLINICAL_DOCS_EXTRACTION_CONFIG`). The response is a JSON with `DOCUMENT_CLASSIFICATION`, `COMPLEX_TABLES_FLAG`, `IMAGE_FLAG`.

### Config-Driven Field Extraction (responseFormat from config table)

The `CLINICAL_DOCS_EXTRACTION_CONFIG` table is the runtime config, derived from the authoritative spec layer at `references/document_type_specs.yaml`. Type-specific field extraction still uses `AI_EXTRACT`:

```sql
AI_EXTRACT(
    file => TO_FILE(stage, path),
    responseFormat => {db}.{schema}.BUILD_DOC_TYPE_EXTRACTION_JSON(doc_type)
)
```

### AI_AGG for Split Documents
```sql
AI_AGG(page_content, '{extraction_prompt}')
```
Groups by parent document, extracts across all pages.

### AI_PARSE_DOCUMENT Mode Selection
```sql
CASE
    WHEN complex_tables_flag = 'YES' OR image_flag = 'YES' THEN
        AI_PARSE_DOCUMENT(file, {'mode': 'LAYOUT', 'page_split': true, 'extract_images': true})
    ELSE
        AI_PARSE_DOCUMENT(file, {'mode': 'OCR', 'page_split': true})
END
```

## Execution Notes (CRITICAL for CoCo agents)

### 1. IDENTIFIER() Limitation in DDL
Snowflake's `IDENTIFIER()` does NOT support `||` concatenation in DDL. Use `EXECUTE IMMEDIATE` with string concatenation instead.

### 2. Connection Parameter
`snowflake_sql_execute` may route to IDE's default connection, ignoring the `connection` parameter. Always verify with `snow sql -c {connection} -q "SELECT CURRENT_ACCOUNT();"` first.

### 3. Execution Method
| Method | When to Use |
|--------|------------|
| `snowflake_sql_execute` | **DEFAULT for ALL SQL** — DDL, queries, simple procs |

**NEVER use `snow` CLI** (`snow stage copy`, `snow sql -q`, `snow sql -f`). The CLI uses a different connection/role than `snowflake_sql_execute`, causing "Database not found" errors.

### 4. Parameterized Proc + Hardcoded FQN for DDL
The `GENERATE_DYNAMIC_OBJECTS()` proc is **fully parameterized** — pass db/schema/warehouse/stage as arguments. No placeholder substitution needed.
For DDL steps (CREATE TABLE, CREATE STAGE), replace `$V_DB`, `$V_SCHEMA` with actual values before execution via CLI. The CLI treats `$VAR` as shell variables.

### 5. Timeout Prevention
Split large DDL batches into 3-4 statements maximum.

## Snowflake Scripting Constraints

| # | Rule | Error Prevented |
|---|------|----------------|
| 1 | No f-strings with `\n` inside `$$` blocks | `unterminated string literal` |
| 2 | No nested `$$` delimiters | `unexpected '$'` |
| 3 | `snow sql -f` cannot execute session variables + `$$` | Empty variable expansion |
| 4 | DECLARE cursors cannot reference variables | `unexpected 'v_fqn'` |
| 5 | INFORMATION_SCHEMA not visible in-transaction | Empty result set |
| 6 | Inline FOR cursors don't support field access | `invalid identifier` |
| 7 | DELETE before INSERT for config seeding | Duplicate rows |
| 8 | COALESCE requires 2+ arguments | `requires at least two arguments` |

## Platform Skill References

| Reference | Path | Used For |
|-----------|------|----------|
| Pricing & constraints | `document-intelligence/SKILL.md` | Cost estimation |
| Extraction workflow | `document-intelligence/references/extraction.md` | Test-before-batch |
| Parsing workflow | `document-intelligence/references/parsing.md` | Mode selection |
| Pipeline templates | `document-intelligence/references/pipeline.md` | Stream + Task patterns |
| Doc type specs | `references/document_type_specs.yaml` | Authoritative field definitions (CKE spec layer) |
| CKE metadata pattern | `references/metadata_as_cke.md` | How specs feed config dynamically |

## Prerequisites

1. Cortex AI features enabled (AI_PARSE_DOCUMENT, AI_EXTRACT, AI_AGG)
2. Pipeline objects created via `scripts/dynamic_pipeline_setup.sql`
3. Pipeline stored procedures created from modular `scripts/proc_*.sql` files (see §"Creating Pipeline Stored Procedures" below)

## Creating Pipeline Stored Procedures (Modular Files)

The 6 pipeline stored procedures are defined as **individual SQL files** in `scripts/proc_*.sql`. Each file uses `$$` delimiters (no nested EXECUTE IMMEDIATE escaping) and `{db}/{schema}` placeholder tokens.

| File | Procedure | Language |
|------|-----------|----------|
| `proc_preprocess_clinical_docs.sql` | PREPROCESS_CLINICAL_DOCS | Python |
| `proc_classify_metadata.sql` | EXTRACT_DOCUMENT_CLASSIFICATION_METADATA | SQL |
| `proc_extract_type_specific.sql` | EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES | SQL |
| `proc_classify_aggregated.sql` | CLASSIFY_AGGREGATED_DOCUMENTS | SQL |
| `proc_extract_with_ai_agg.sql` | EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG | SQL |
| `proc_parse_with_images.sql` | CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2 | SQL |

**To create each procedure:**
1. Read the file contents
2. Replace `{db}` → actual database name, `{schema}` → actual schema name
3. For `proc_preprocess_clinical_docs.sql`, also replace `{stage}` → actual stage name
4. Execute via `snowflake_sql_execute` — the `$$` delimiters work directly with no escaping issues

**Why modular?** The legacy `stored_procedures.sql` wraps all 6 procs in a single EXECUTE IMMEDIATE block with 4+ levels of quote escaping (`''''text''''`). This makes it impossible to execute via `snowflake_sql_execute` or `snow sql`. The modular files eliminate all escaping complexity.

> **Legacy file**: `stored_procedures.sql` is retained for reference but should NOT be used for procedure creation. Use the individual `proc_*.sql` files instead.

## Execution Notes (CRITICAL for CoCo agents)

These notes address known issues when executing the pipeline SQL scripts. Failure to follow them will cause errors.

### 1. IDENTIFIER() Limitation in DDL

Snowflake's `IDENTIFIER()` function does **NOT** support expression concatenation (`||`) inside DDL statements like `CREATE SCHEMA`, `CREATE STAGE`, or `CREATE TABLE`. It only works with a single session variable reference (e.g., `IDENTIFIER($V_DB)`).

**Broken:**
```sql
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($V_DB || '.' || $V_SCHEMA);  -- ERROR: unexpected '||'
```

**Fixed (use EXECUTE IMMEDIATE):**
```sql
EXECUTE IMMEDIATE 'CREATE SCHEMA IF NOT EXISTS ' || $V_DB || '.' || $V_SCHEMA;
```

The setup scripts already use EXECUTE IMMEDIATE for all multi-part DDL.

### 2. Connection Parameter

**Before executing ANY SQL**, verify the target connection works:
```sql
SELECT CURRENT_ACCOUNT(), CURRENT_ROLE(), CURRENT_DATABASE();
```
If this returns the wrong account, ask the user for the correct connection name and pass it via the `connection` parameter of `snowflake_sql_execute`.

### 3. Execution Method

| Method | When to Use | Notes |
|--------|------------|-------|
| `snowflake_sql_execute` tool | **DEFAULT for ALL SQL** | Supports `connection` parameter, handles quoting natively. Use for DDL, queries, simple procs. |
| Snowflake worksheet (Snowsight) | **Fallback** | Full file works. Best for manual execution. |

**CRITICAL — DO NOT USE `snow` CLI**: `snow stage copy`, `snow sql -q`, and `snow sql -f` all use a separate CLI connection/role that may differ from `snowflake_sql_execute`. This causes "Database not found" errors. **Always use `snowflake_sql_execute` for everything.**

**CRITICAL — GENERATE_DYNAMIC_OBJECTS** (see also Constraints #16 and #17):
> **DO NOT CREATE THIS STORED PROCEDURE.** It **WILL** fail via `snowflake_sql_execute` every time — two separate patterns inside the `$$` body are incompatible with the CoCo tool:
> - `EXECUTE IMMEDIATE '...' INTO :var` → `unexpected 'INTO'` (Constraint #16)
> - `IDENTIFIER(v_fqn || '...')` → `unexpected 'v_fqn'` (Constraint #17)
>
> **Required approach — execute steps individually:**
> 1. Open `scripts/dynamic_pipeline_setup.sql` Step 6 and read each numbered sub-step (0 through 7b)
> 2. For each sub-step, write a standalone SQL statement replacing `:v_fqn` → `'{db}.{schema}'`, `:v_db` → `'{db}'`, `:v_stage_fqn` → `'{db}.{schema}.{stage}'`
> 3. Execute each via `snowflake_sql_execute` — they are plain SQL (no `$$`, no variables)
> 4. Run sequentially — later steps depend on earlier results
> 5. For the Step 3 cursor loop, query the config table first to get the list of view names/doc types, then create each pivot view individually

### 4. Parameterized Proc + Hardcoded FQN for DDL (Required for CLI Execution)

The setup scripts use session variables (`$V_DB`, `$V_SCHEMA`) which are **incompatible with `snow sql` CLI** because:
- `snow sql -q` treats `$VAR` as shell variables (empty)
- `snow sql -f` loses session state between semicolons

**Required approach for DDL Steps 0-5**: Generate SQL files with hardcoded FQN values:
1. Read the script template
2. Replace ALL `$V_DB`, `$V_SCHEMA`, `$V_WAREHOUSE` with actual values from user
3. Replace ALL `IDENTIFIER($V_...)` with hardcoded fully-qualified names
4. Write to a temp file
5. Execute via `snow sql -c {connection} -f <temp_file>`

**Step 6 (GENERATE_DYNAMIC_OBJECTS) is different**: The proc is **fully parameterized**. No FQN substitution in the proc body. Just create it and call:
```sql
CALL {db}.{schema}.GENERATE_DYNAMIC_OBJECTS('{db}', '{schema}', '{warehouse}', '{stage}');
```
Cursors inside the proc use the RESULTSET pattern (`EXECUTE IMMEDIATE` → `RESULTSET` → `CURSOR FOR rs`) so they can reference the parameter-derived variables at runtime.

### 5. Timeout Prevention

Large DDL batches (8+ CREATE TABLE statements) can timeout when run as a single call. Split into batches of 3-4 statements maximum. The script's STEP comments provide natural split points.

## Snowflake Scripting Constraints

These rules prevent the 8 most common runtime errors encountered when building Snowflake Scripting procedures for this pipeline. **Every SQL block generated by this skill MUST follow these rules.**

| # | Rule | Error Prevented | Details |
|---|------|----------------|----------|
| 1 | **No f-strings with `\n` inside `$$` blocks** | `SyntaxError: unterminated string literal` | Use `chr(10)` + string concatenation instead of f-strings containing `\n` in Python UDFs wrapped in `$$`. |
| 2 | **No nested `$$` delimiters** | `syntax error: unexpected '$'` | Snowflake does not support `EXECUTE IMMEDIATE $$ ... CREATE PROCEDURE ... AS $$ ... $$ ... $$`. Use `{db}/{schema}` placeholders substituted at creation time instead. |
| 3 | **`snow sql -f` cannot execute session variables + `$$`** | Empty variable expansion / partial execution | The CLI loses session state at `$$` boundaries and treats `$V_DB` as shell variables. Use `snowflake_sql_execute` tool or Snowsight worksheet instead. |
| 4 | **DECLARE cursors cannot reference variables** | `syntax error ... unexpected 'v_fqn'` | Cursors declared in the DECLARE block are compiled before BEGIN runs, so they cannot use variables. **Fix**: Use RESULTSET pattern inside BEGIN: `LET rs RESULTSET := (EXECUTE IMMEDIATE '...' \|\| :var); LET cur CURSOR FOR rs; FOR rec IN cur DO`. |
| 5 | **INFORMATION_SCHEMA is not visible in-transaction** | Empty result set / missing rows | Views/tables created earlier in the same procedure are not visible in INFORMATION_SCHEMA until the transaction commits. Read from the config table (`CLINICAL_DOCS_EXTRACTION_CONFIG`) instead. |
| 6 | **Inline FOR cursors don't support field access** | `invalid identifier 'REC.COLUMN_NAME'` | Only named cursors (declared in DECLARE) support `rec.FIELD_NAME` access. Always use named cursors. |
| 7 | **DELETE before INSERT for config seeding** | Duplicate rows / PIVOT column collision | Always use DELETE + INSERT (idempotent pattern) when seeding config tables. Never INSERT without clearing first. |
| 8 | **COALESCE requires 2+ arguments** | `COALESCE requires at least two arguments` | When dynamically building COALESCE from a variable-length list, always append `, NULL` to guarantee the minimum. |
| 9 | **PIVOT column quoting** | `invalid identifier 'MRN'` | Snowflake PIVOT creates columns with literal single quotes in names. To reference them, use double-quoted identifiers containing single quotes: `"'MRN'"`. In dynamic SQL inside `$$`, produce: `'''' \|\| FIELD_NAME \|\| ''''`. |
| 10 | **TO_FILE does not support FQN stage names** | `invalid argument for function [TO_FILE]` | `TO_FILE(@DB.SCHEMA.STAGE, path)` fails. Set `USE DATABASE/SCHEMA` context first, then use short stage name: `TO_FILE(@STAGE, path)`. |
| 11 | **AI_EXTRACT unreliable for classification — RESOLVED** | All docs classified identically | `AI_EXTRACT` with `responseFormat` returned the same classification for all documents. **Fixed**: `EXTRACT_DOCUMENT_CLASSIFICATION_METADATA` now uses `AI_PARSE_DOCUMENT` (OCR) + `AI_COMPLETE` (two-step) for classification. Field extraction still uses `AI_EXTRACT`. |
| 12 | **Use AI_* top-level functions** | `Invalid argument types for function` | Use `AI_COMPLETE`, `AI_PARSE_DOCUMENT(TO_FILE(...))`, `AI_EXTRACT`, `AI_AGG`. Do NOT use deprecated `SNOWFLAKE.CORTEX.COMPLETE` or `SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@stage, path, opts)`. The `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` and `SNOWFLAKE.CORTEX.DATA_AGENT_RUN` are Cortex Search/Agent APIs and remain unchanged. |
| 13 | **Semantic View DIMENSIONS syntax is REVERSED from normal SQL** | `invalid identifier` or `syntax error` | **CRITICAL**: DIMENSIONS use `TABLE.NEW_DIM_NAME AS EXISTING_COLUMN` — the NEW name is on the LEFT, the EXISTING column is on the RIGHT. This is the **OPPOSITE** of standard SQL (`SELECT col AS alias`). Example: `DISCHARGE_SUMMARY_V.DS_MRN AS MRN` (DS_MRN = new dimension name, MRN = physical column). **WRONG**: `TABLE.MRN AS DS_MRN` (DS_MRN is not a column). Always run `DESCRIBE VIEW <view>` to verify column names before defining dimensions. |
| 14 | **Classification underscore normalization** | Config mismatch / empty extraction results | AI models return classifications with underscores (`DISCHARGE_SUMMARY`) but config uses spaces (`DISCHARGE SUMMARY`). After classification, always run: `UPDATE ... SET FIELD_VALUE = REPLACE(FIELD_VALUE, '_', ' ') WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION'`. |
| 15 | **Split documents must be classified before extraction** | NULL classification for split docs | Split documents (from preprocessing) have parent documents that are NOT classified by `EXTRACT_DOCUMENT_CLASSIFICATION_METADATA`. Parse split docs first, then call `CLASSIFY_AGGREGATED_DOCUMENTS()` BEFORE the extraction phase. |
| 16 | **`EXECUTE IMMEDIATE ... INTO :var` inside `$$` fails via snowflake_sql_execute** | `syntax error ... unexpected 'INTO'` | The `snowflake_sql_execute` tool cannot parse `EXECUTE IMMEDIATE '...' INTO :v_dup_count` inside a `$$`-delimited stored procedure body. This pattern works in Snowsight worksheets but fails when sent through the CoCo tool. **Fix**: Do NOT create the proc. Execute each step as individual SQL statements, replacing `:v_dup_count` with a direct query. |
| 17 | **`IDENTIFIER(var \|\| '...')` inside `$$` fails via snowflake_sql_execute** | `syntax error ... unexpected 'v_fqn'` | `SELECT ... FROM IDENTIFIER(v_fqn \|\| '.TABLE_NAME')` inside a `$$` proc body causes parse errors when sent through `snowflake_sql_execute`. **Fix**: Do NOT create the proc. Execute each step as individual SQL with hardcoded FQN values (e.g., `FROM {db}.{schema}.TABLE_NAME`). |
| 18 | **Semantic View DIMENSION — right side of AS must be a real column** | `invalid identifier` | In `TABLE.X AS Y`, Y **must be an existing physical column** in the table/view. PIVOT views generate columns from `FIELD_NAME` values (e.g., MRN, PATIENT_NAME). `TABLE.DS_MRN AS MRN` works (MRN exists); `TABLE.MRN AS DS_MRN` fails (DS_MRN does not exist). Always verify with `DESCRIBE VIEW <pivot_view>` first. See also constraint 13. |
