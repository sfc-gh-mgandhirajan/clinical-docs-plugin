# Metadata as CKE — Dynamic Document Type Discovery

## Overview

This document describes the pattern for treating clinical document metadata as a
**Cortex Knowledge Extension (CKE)** — a dynamically discoverable spec layer that
feeds into the extraction pipeline at runtime, rather than a rigid config table
that must be manually populated with SQL INSERTs.

This approach follows the same pattern used by the DICOM imaging skill's
`data-model-knowledge` sub-skill, adapted for the clinical documents domain.

## Architecture

```
references/document_type_specs.yaml        ← AUTHORITATIVE spec layer (human-authored)
    │
    ├──→ Cortex Search Service             ← CKE: skills query specs dynamically
    │    (CLINICAL_DOCS_SPECS_SEARCH_SVC)     at runtime for prompts, fields, etc.
    │
    └──→ CLINICAL_DOCS_EXTRACTION_CONFIG   ← DERIVED config table (seeded from specs)
         │
         └──→ GENERATE_DYNAMIC_OBJECTS()   ← Execution engine (unchanged)
              │
              ├── Pivot views, Semantic View, refresh task
              └── DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_REFERENCE
                  └── CLINICAL_DOCS_MODEL_SEARCH_SVC (schema metadata CKE)
```

### Key Insight: Two CKE Layers

| CKE Layer | Source | Answers | Consumers |
|-----------|--------|---------|-----------|
| **Spec CKE** | `document_type_specs.yaml` | "What fields does a discharge summary have?" "What prompt extracts MRN?" | Gates (E4-E5), OTHER onboarding loop, customers |
| **Schema CKE** | `CLINICAL_DOCS_MODEL_REFERENCE` (auto-generated) | "What tables exist?" "Which columns contain PHI?" "How are tables related?" | data-model-knowledge sub-skill, DDL generation, governance |

## How It Works

### Before (Rigid Config)

```
Customer → Write SQL INSERTs into EXTRACTION_CONFIG → GENERATE_DYNAMIC_OBJECTS()
```

The customer must understand the config table schema (CONFIG_TYPE, DOC_TYPE,
FIELD_NAME, EXTRACTION_QUESTION, TARGET_COLUMN, DATA_TYPE, DISPLAY_ORDER,
VIEW_NAME, IS_IDENTITY_FIELD) to add a new document type.

### After (CKE-Driven)

```
Customer → Edit document_type_specs.yaml → Seed config from specs → GENERATE_DYNAMIC_OBJECTS()
         OR
Customer → Describe doc type in natural language → Skill queries Spec CKE →
           Auto-generates config rows → GENERATE_DYNAMIC_OBJECTS()
```

The customer describes what they want. The skill discovers the spec and generates
the correct config rows.

## Comparison: DICOM vs Clinical Docs

| Aspect | DICOM Pattern | Clinical Docs Pattern |
|--------|--------------|----------------------|
| Source of truth | Excel spreadsheet | `document_type_specs.yaml` |
| Intermediate | CSV export | Config table (seeded from YAML) |
| Search service | `DICOM_MODEL_SEARCH_SVC` | `CLINICAL_DOCS_MODEL_SEARCH_SVC` + `CLINICAL_DOCS_SPECS_SEARCH_SVC` |
| Update flow | Edit spreadsheet → export CSV → reload table | Edit YAML → seed config → `GENERATE_DYNAMIC_OBJECTS()` |
| Preflight check | Yes (table + search service probes) | Yes (same pattern) |
| Fallback | Hardcoded schemas in SKILL.md | `document_type_specs.yaml` (always available on disk) |
| Dynamic generation | No (static reference) | Yes (Step 7 auto-generates schema corpus from config) |

## Adding a New Document Type (CKE Flow)

### Option A: Edit the Spec File Directly

1. Add a new entry to `references/document_type_specs.yaml`
2. Seed the config table from the spec (SQL generation from YAML)
3. `CALL GENERATE_DYNAMIC_OBJECTS()`

### Option B: Interactive Discovery (OTHER Onboarding Loop)

1. Pipeline classifies a document as OTHER
2. Gate E9 fires — asks user if they want to configure extraction
3. Skill samples the document, auto-detects fields via AI
4. Skill queries Spec CKE for similar doc types to suggest defaults
5. User confirms the field spec
6. Skill writes both the config rows AND updates `document_type_specs.yaml`
7. `CALL GENERATE_DYNAMIC_OBJECTS()`

### Option C: Natural Language (Future)

1. User says: "I have operative notes with surgery date, procedure, and surgeon"
2. Skill queries Spec CKE for the closest matching template
3. Generates a complete spec entry with extraction prompts
4. User confirms → config seeded → `GENERATE_DYNAMIC_OBJECTS()`

## Spec CKE Setup

The Spec CKE table and search service are now created automatically by `dynamic_pipeline_setup.sql`:

- **Step 2c**: Creates `CLINICAL_DOCS_SPECS_REFERENCE` table
- **Step 2d**: Creates `CLINICAL_DOCS_SPECS_SEARCH_SVC` Cortex Search Service
- **Step 7b**: `GENERATE_DYNAMIC_OBJECTS()` auto-refreshes the table from config

To recreate manually if needed:

```sql
CREATE TABLE IF NOT EXISTS {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_REFERENCE (
    SEARCH_TEXT VARCHAR,
    DOC_TYPE VARCHAR,
    FIELD_NAME VARCHAR,
    EXTRACTION_QUESTION VARCHAR,
    DATA_TYPE VARCHAR,
    DISPLAY_ORDER NUMBER,
    VIEW_NAME VARCHAR,
    IS_IDENTITY_FIELD VARCHAR,
    CONTAINS_PHI VARCHAR,
    DESCRIPTION VARCHAR
);

CREATE OR REPLACE CORTEX SEARCH SERVICE
    {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_SEARCH_SVC
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

### Loading Specs into the Table

```sql
INSERT INTO {db}.DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_REFERENCE
    (SEARCH_TEXT, DOC_TYPE, FIELD_NAME, EXTRACTION_QUESTION, DATA_TYPE,
     DISPLAY_ORDER, VIEW_NAME, IS_IDENTITY_FIELD, CONTAINS_PHI, DESCRIPTION)
VALUES
    ('DISCHARGE SUMMARY MRN Medical Record Number', 'DISCHARGE SUMMARY', 'MRN',
     'What is the Medical Record Number (MRN)?', 'VARCHAR(100)', 1,
     'DISCHARGE_SUMMARY_V', 'MRN', 'YES',
     'Hospital discharge summaries with admission/discharge dates and diagnoses'),
    -- ... (generated from document_type_specs.yaml)
;
```

## Relationship to Existing Architecture

This change is **additive** — nothing breaks:

| Component | Change | Impact |
|-----------|--------|--------|
| `GENERATE_DYNAMIC_OBJECTS()` | None | Still reads from `EXTRACTION_CONFIG`, still produces all dynamic objects |
| `EXTRACTION_CONFIG` table | Now DERIVED from specs | Same schema, same data, different authoring flow |
| `DATA_MODEL_KNOWLEDGE` | Unchanged | Step 7 still auto-refreshes from config |
| Gate E4-E5 | Can optionally query Spec CKE | Richer defaults for doc type confirmation |
| OTHER onboarding (E9) | Can query Spec CKE for templates | Better auto-detection suggestions |
| `document_type_specs.yaml` | NEW — authoritative spec layer | Always available as fallback, human-readable |

## Design Principles

1. **Specs are the source of truth** — the YAML file is what humans edit
2. **Config is derived** — the SQL table is generated from specs, not hand-authored
3. **CKE is optional** — the Cortex Search over specs is a runtime optimization, not a requirement
4. **Fallback always works** — if CKE is unavailable, skills read specs from disk
5. **GENERATE_DYNAMIC_OBJECTS() is untouched** — the execution engine stays stable
