---
name: data-model-knowledge
parent_skill: hcls-provider-cdata-clinical-docs
description: "Query the clinical documents data model reference via Cortex Search Service. Answers questions about table structures, column types, PHI fields, relationships, and DDL generation for the clinical document extraction schema."
tools: ["snowflake_sql_execute"]
---

# Clinical Documents Data Model Knowledge

This skill provides runtime schema awareness for the clinical documents extraction data model by querying Cortex Search Services. It supports two CKE layers:

| CKE Layer | Service | Answers |
|-----------|---------|---------|
| **Schema CKE** | `CLINICAL_DOCS_MODEL_SEARCH_SVC` | "What tables exist?" "Which columns contain PHI?" |
| **Spec CKE** (optional) | `CLINICAL_DOCS_SPECS_SEARCH_SVC` | "What fields does a discharge summary have?" "What prompt extracts MRN?" |

## Preflight Check (REQUIRED — Run Before Any Query)

Before executing any data model search, verify both the reference table and Cortex Search Service exist:

### Check 1: Schema Reference Table

```sql
SELECT COUNT(*) FROM {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_REFERENCE LIMIT 1;
```

### Check 2: Schema Cortex Search Service

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "test", "columns": ["SEARCH_TEXT"], "limit": 1}'
);
```

### Check 3: Spec Search Service (Optional)

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_SEARCH_SVC',
    '{"query": "test", "columns": ["SEARCH_TEXT"], "limit": 1}'
);
```

| Check 1 | Check 2 | Check 3 | Status | Action |
|---------|---------|---------|--------|--------|
| OK | OK | OK | FULL | Proceed with dynamic queries (schema + specs) |
| OK | OK | FAIL | READY | Schema CKE available; specs fall back to `document_type_specs.yaml` on disk |
| OK | FAIL | * | PARTIAL | Table exists but search service missing — guide user to recreate (see Setup) |
| FAIL | FAIL | * | MISSING | Guide user through full Setup below |
| ERROR | ERROR | * | ERROR | Show error, check permissions on `{db}.DATA_MODEL_KNOWLEDGE` |

### Fallback (When MISSING or PARTIAL)

If the Cortex Search Service is not available:
- **Use `references/document_type_specs.yaml`** for doc type specs (field definitions, extraction prompts, PHI flags)
- **Use hardcoded schema definitions** from the Data Model Overview table below
- **Inform the user**: "Data model search service is not available — using local spec definitions. Results may not reflect the latest schema updates."
- **Never block the parent skill** — the router and sub-skills must continue to work with fallbacks

### Auto-Detection for Router and Sub-Skills

The router runs this preflight as part of its Step 0 (Data Model Knowledge pre-step):
1. Run checks 1-3 above
2. If FULL or READY — execute Step 0 to query CKE services, pass results to sub-skill as grounding context
3. If MISSING — skip Step 0, sub-skills fall back to `document_type_specs.yaml` and hardcoded schemas
4. Set `$DMK_AVAILABLE` context flag for sub-skills to check:
   - `FULL` = schema CKE + spec CKE both available
   - `READY` = schema CKE only
   - `PARTIAL` = table exists, no search service
   - `MISSING` = no data model knowledge infrastructure

## Architecture

```
references/document_type_specs.yaml (authoritative spec layer)
    │
    ├──→ {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_REFERENCE (optional)
    │    └──→ CLINICAL_DOCS_SPECS_SEARCH_SVC (Spec CKE)
    │
    └──→ CLINICAL_DOCS_EXTRACTION_CONFIG (derived from specs)
         └──→ GENERATE_DYNAMIC_OBJECTS() Step 7
              └──→ {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_REFERENCE
                   └──→ CLINICAL_DOCS_MODEL_SEARCH_SVC (Schema CKE)
```

## When to Load

Healthcare clinical-docs router or any skill that needs to reference the clinical documents data model at runtime instead of relying on hardcoded schema definitions.

## Setup

Both CKE layers are created by `dynamic_pipeline_setup.sql`:

- **Step 2b**: Creates `CLINICAL_DOCS_MODEL_REFERENCE` table (Schema CKE backing table)
- **Step 2c**: Creates `CLINICAL_DOCS_SPECS_REFERENCE` table (Spec CKE backing table)
- **Step 2d**: Creates both Cortex Search Services
- **Step 7**: `GENERATE_DYNAMIC_OBJECTS()` auto-refreshes Schema CKE from config table
- **Step 7b**: `GENERATE_DYNAMIC_OBJECTS()` auto-refreshes Spec CKE from config table

If the search services do not exist but tables do, recreate services manually:

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC
    ON search_text
    ATTRIBUTES table_name, column_name, data_type, category, contains_phi
    WAREHOUSE = {warehouse}
    TARGET_LAG = '1 day'
AS (
    SELECT search_text, table_name, column_name, data_type, domain_tag,
           category, description, constraints, contains_phi, relationships
    FROM {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_REFERENCE
);

CREATE OR REPLACE CORTEX SEARCH SERVICE {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_SEARCH_SVC
    ON search_text
    ATTRIBUTES doc_type, field_name, data_type, contains_phi
    WAREHOUSE = {warehouse}
    TARGET_LAG = '1 day'
AS (
    SELECT search_text, doc_type, field_name, extraction_question,
           data_type, display_order, view_name, is_identity_field,
           contains_phi, description
    FROM {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_REFERENCE
);
```

## Query Patterns

### 1. Find Tables for a Concept

### 🛑 MANDATORY STOP — GATE M1: Concept Query

Use `ask_user_question` to ask: "What concept are you looking for? (e.g., patient demographics, extraction config, parsed content)" **DO NOT run a search query without asking the user what they want to find.**

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "{user_concept}", "columns": ["table_name", "column_name", "data_type", "description"]}'
);
```

### 2. Generate DDL from Metadata

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "all columns in {TABLE_NAME}", "columns": ["column_name", "data_type", "constraints", "description"]}'
);
```

Use the results to reconstruct `CREATE TABLE` or `CREATE VIEW` DDL dynamically with Cortex AI:

```sql
WITH model_knowledge AS (
    SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
        '{"query": "{TABLE_NAME} columns definitions constraints", "columns": ["table_name", "column_name", "data_type", "constraints", "description"]}'
    ) AS context
)
SELECT AI_COMPLETE(
    'llama3.1-70b',
    'Generate a Snowflake CREATE TABLE DDL statement from this data model reference. Use the exact column names, data types, and constraints from the reference. Reference: ' || context::STRING
) AS generated_ddl
FROM model_knowledge;
```

### 3. Identify PHI Columns

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "columns containing PHI protected health information", "columns": ["table_name", "column_name", "description", "contains_phi"]}'
);
```

### 4. Explore Relationships

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "foreign key relationships joins between tables", "columns": ["table_name", "column_name", "relationships", "description"]}'
);
```

### 5. Category-Specific Exploration

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "{category} tables and columns", "columns": ["table_name", "column_name", "data_type", "category", "description"]}'
);
```

Categories: Document Management, Parse Output, Classification, Extraction Output, AI-Ready Layer, Config, Pivot View, Identity Linkage

### 6. Query Doc Type Specs (Spec CKE)

If `$DMK_AVAILABLE = FULL`:

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_SEARCH_SVC',
    '{"query": "{doc_type} extraction fields", "columns": ["doc_type", "field_name", "extraction_question", "data_type", "contains_phi"]}'
);
```

If Spec CKE is unavailable, read from `references/document_type_specs.yaml` on disk.

## Data Model Overview

| Category | Tables/Views | Purpose |
|----------|-------------|---------|
| Document Management | DOCUMENT_HIERARCHY | Tracks parent/child doc relationships and splitting |
| Parse Output | DOCS_PARSE_OUTPUT | Page-level content from AI_PARSE_DOCUMENT |
| Classification | DOC_CLASSIFICATION_METADATA_ROWS | AI_EXTRACT classification results (row-based) |
| Extraction Output | DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT | Type-specific field extraction results |
| AI-Ready Layer | CLINICAL_DOCUMENTS_RAW_CONTENT | Final searchable content with presigned URLs |
| Config | DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG | Drives classification extraction prompts |
| Config | DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG | Drives type-specific extraction prompts per doc type |
| Config | CLINICAL_DOCS_EXTRACTION_CONFIG | Master config table driving the entire pipeline (IS_IDENTITY_FIELD for identity resolution) |
| Pivot Views | Auto-generated per doc type by GENERATE_DYNAMIC_OBJECTS() | Pivoted structured views — one per doc type with a VIEW_NAME in extraction config |
| Identity Linkage | MRN_PATIENT_MAPPING | Distinct MRN-to-patient-name mapping derived from extracted clinical documents |

## Integration with Other Sub-Skills

- **clinical-document-extraction**: Queries this service in Step 0 to understand current schema before pipeline execution
- **clinical-docs-search**: Uses schema context to understand which columns are searchable
- **clinical-docs-agent**: Uses schema context for Semantic View column awareness
- **Governance workflows**: PHI column identification feeds into masking policy creation
- **OTHER onboarding (Gate E9)**: Queries Spec CKE for similar doc types when auto-detecting fields for unknown document types

## Updating the Data Model

When the clinical docs data model changes:

### Schema CKE (automatic)
Config table changes → `CALL GENERATE_DYNAMIC_OBJECTS()` → Step 7 auto-refreshes `CLINICAL_DOCS_MODEL_REFERENCE` → Search service auto-refreshes based on TARGET_LAG.

### Spec CKE (manual)
1. Edit `references/document_type_specs.yaml`
2. Regenerate INSERT statements from the YAML
3. Load into `CLINICAL_DOCS_SPECS_REFERENCE`
4. Search service auto-refreshes based on TARGET_LAG

## Extending to Other Domains

This dual-CKE pattern (spec layer + auto-generated schema layer) is reusable:

| Domain | Spec File | Schema CKE | Spec CKE |
|--------|-----------|------------|----------|
| Clinical Documents | `document_type_specs.yaml` | `CLINICAL_DOCS_MODEL_SEARCH_SVC` | `CLINICAL_DOCS_SPECS_SEARCH_SVC` |
| DICOM Imaging | `dicom_data_model_reference.xlsx` | `DICOM_MODEL_SEARCH_SVC` | (not yet implemented) |
| FHIR R4 | `fhir_r4_resource_model.xlsx` | `FHIR_MODEL_SEARCH_SVC` | (not yet implemented) |
| OMOP CDM v5.4 | `omop_cdm_v54_model.xlsx` | `OMOP_MODEL_SEARCH_SVC` | (not yet implemented) |
