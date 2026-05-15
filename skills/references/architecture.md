# Clinical Documents Activation — Architecture

## Solution Overview

```
                    ┌──────────────────────────────────┐
                    │  Clinical Documents               │
                    │  (PDF, DOCX, PNG, JPG, TIFF, TXT) │
                    │  on Snowflake Internal Stage       │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  4.1 PREPROCESS_CLINICAL_DOCS     │
                    │  Split large PDFs (>125pg / >100MB)│
                    │  Register all file types           │
                    │  → DOCUMENT_HIERARCHY              │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  4.2 AI_PARSE_DOCUMENT + AI_COMPLETE│
                    │  Classification (non-split only)   │
                    │  Parse(OCR) → Classify(LLM)        │
                    │  → DOC_CLASSIFICATION_METADATA_ROWS│
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  4.2c OTHER Detection &           │
                    │  Onboarding Loop (interactive)    │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  4.3 AI_EXTRACT (single docs)     │
                    │  Type-specific field extraction    │
                    │  → DOC_TYPE_SPECIFIC_VALUES_...    │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │  4.4 AI_PARSE_DOCUMENT (all docs) │
                    │  OCR / LAYOUT mode                │
                    │  + Image extraction                │
                    │  + INJECT_IMAGE_DESCRIPTIONS       │
                    │  → DOCS_PARSE_OUTPUT               │
                    └──────────────┬───────────────────┘
                                   │
               ┌───────────────────┼───────────────────┐
               │                   │                    │
               ▼                   │                    ▼
     ┌──────────────────┐          │      ┌──────────────────────┐
     │ 4.5 AI_AGG       │          │      │ DOCS_PARSE_OUTPUT    │
     │ Classify split   │          │      │ _STREAM (APPEND_ONLY)│
     │ docs across pages│          │      └──────────┬───────────┘
     └────────┬─────────┘          │                  │
              │                    │                  │
     ┌────────▼─────────┐         │                  │
     │ 4.6 AI_AGG       │         │                  │
     │ Extract fields   │         │                  │
     │ from split docs  │         │                  │
     └────────┬─────────┘         │                  │
              │                    │                  │
              └────────────────────┼──────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │ 4.7 REFRESH_RAW_CONTENT_TASK      │
                    │ 1. Materialize stream →           │
                    │    TEMP_STREAM_SNAPSHOT            │
                    │ 2. INSERT non-split docs          │
                    │ 3. INSERT split docs               │
                    │ 4. DROP temp table                 │
                    │ 5. Refresh presigned URLs          │
                    │ + DOCUMENT_CLASSIFICATION          │
                    │   (LEFT JOIN to classif.)          │
                    │ + PATIENT_NAME / MRN               │
                    │   (COALESCE from pivot views)      │
                    │ → CLINICAL_DOCUMENTS_RAW_CONTENT   │
                    └──────────────┬───────────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                     ▼
        ┌───────────┐   ┌───────────────┐    ┌───────────┐
        │ Cortex    │   │ Semantic View │    │ Streamlit │
        │ Search    │   │ + Cortex Agent│    │ Viewer    │
        │ Service   │   └───────────────┘    └───────────┘
        └───────────┘
              │
              │        ┌──────────────────────────────────┐
              └───────→│ DATA_MODEL_KNOWLEDGE schema       │
                       │ CLINICAL_DOCS_MODEL_REFERENCE     │
                       │ → CLINICAL_DOCS_MODEL_SEARCH_SVC  │
                       │   (Schema CKE — auto-generated)   │
                       │                                    │
                       │ CLINICAL_DOCS_SPECS_REFERENCE      │
                       │ → CLINICAL_DOCS_SPECS_SEARCH_SVC   │
                       │   (Spec CKE — from YAML specs)     │
                       └──────────────────────────────────┘

   references/document_type_specs.yaml    ← AUTHORITATIVE spec layer
       │
       ├──→ Spec CKE (optional Cortex Search over doc type definitions)
       └──→ EXTRACTION_CONFIG table (derived from specs)
```

**Flow**: Steps 4.1–4.4 run sequentially for all documents. After 4.4, the split-doc path (4.5–4.6) uses `DOCS_PARSE_OUTPUT` to classify and extract across pages. The stream feeds 4.7 for incremental refresh.

## Pipeline Step Mapping

| Architecture Step | SKILL.md Step | Procedure / Function | Input Table | Output Table |
|-------------------|---------------|----------------------|-------------|-------------|
| Preprocess | 4.1 | PREPROCESS_CLINICAL_DOCS | Stage files | DOCUMENT_HIERARCHY |
| Classify (single) | 4.2 | EXTRACT_DOCUMENT_CLASSIFICATION_METADATA | DOCUMENT_HIERARCHY + Stage (AI_PARSE_DOCUMENT + AI_COMPLETE) | DOC_CLASSIFICATION_METADATA_ROWS |
| OTHER detection | 4.2c | (interactive in SKILL.md) | DOC_CLASSIFICATION_METADATA_ROWS | CLINICAL_DOCS_EXTRACTION_CONFIG (new rows) |
| Extract (single) | 4.3 | EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES | DOC_CLASSIFICATION_METADATA_ROWS + Stage | DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT |
| Parse | 4.4 | CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2 | DOCUMENT_HIERARCHY + Stage | DOCS_PARSE_OUTPUT |
| Classify (split) | 4.5 | CLASSIFY_AGGREGATED_DOCUMENTS | DOCS_PARSE_OUTPUT | DOC_CLASSIFICATION_METADATA_ROWS |
| Extract (split) | 4.6 | EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG | DOCS_PARSE_OUTPUT + Config | DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT |
| Refresh | 4.7 | REFRESH_RAW_CONTENT_TASK | DOCS_PARSE_OUTPUT_STREAM + Pivot Views | CLINICAL_DOCUMENTS_RAW_CONTENT |

## Key Design Decisions

1. **Config-driven extraction**: Extraction schemas stored in `CLINICAL_DOCS_EXTRACTION_CONFIG` table, derived from `references/document_type_specs.yaml`. UDFs (`BUILD_DOCUMENT_CLASIFICATION_EXTRACTION_JSON`, `BUILD_DOC_TYPE_EXTRACTION_JSON`) dynamically build `responseFormat` from config at runtime. The YAML spec file is the authoritative source of truth for doc type definitions — the config table is a generated artifact.

2. **Dual-path processing**: Single documents use `AI_EXTRACT` directly (Steps 4.2–4.3); split documents use `AI_AGG` to aggregate across pages (Steps 4.5–4.6). Steps 4.5–4.6 depend on `DOCS_PARSE_OUTPUT` from Step 4.4, so Parse must complete first.

3. **Adaptive parse mode**: Documents are parsed with OCR (default) or LAYOUT (when tables or images detected) based on classification metadata flags (`COMPLEX_TABLES_FLAG`, `IMAGE_FLAG`).

4. **Row-based extraction output (EAV pattern)**: All extracted values stored as `FIELD_NAME`/`FIELD_VALUE` rows in `DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT`, then pivoted into type-specific views by `GENERATE_DYNAMIC_OBJECTS()`. This allows new document types without schema changes.

5. **DOCUMENT_CLASSIFICATION in RAW_CONTENT**: The refresh task LEFT JOINs `DOC_CLASSIFICATION_METADATA_ROWS` to populate `DOCUMENT_CLASSIFICATION` in `CLINICAL_DOCUMENTS_RAW_CONTENT`, enabling search filtering by document type. Documents classified as OTHER still land in RAW_CONTENT (parsed/searchable) but have no pivot view or Semantic View coverage.

6. **OTHER feedback loop**: After classification (Step 4.2c), the extraction SKILL.md detects documents with no matching extraction config and offers an interactive onboarding workflow: sample doc → AI auto-detect fields → confirm config → INSERT rows → `GENERATE_DYNAMIC_OBJECTS()` → re-classify. This ensures no documents silently fall through.

7. **Stream snapshot pattern**: The refresh task materializes `DOCS_PARSE_OUTPUT_STREAM` (APPEND_ONLY) into a `TEMP_STREAM_SNAPSHOT` temporary table before executing dual INSERTs (non-split + split docs). This prevents the second INSERT from seeing an empty stream after the first INSERT advances the stream offset.

8. **IS_IDENTITY_FIELD**: Configurable identity resolution per doc type. Each extraction config row can mark a field as `PATIENT_NAME` or `MRN` via `IS_IDENTITY_FIELD`, and `GENERATE_DYNAMIC_OBJECTS()` uses this to build the correct COALESCE chains in the refresh task.

9. **Multi-format file support**: `PREPROCESS_CLINICAL_DOCS` splits large PDFs and registers non-PDF files (DOCX, PNG, JPG, TIFF, TXT) directly into `DOCUMENT_HIERARCHY` without splitting, so all supported file types flow through the same pipeline.

10. **Platform skill separation**: UI (Streamlit), deployment (SPCS), and governance (masking/row-access) are delegated to platform skills, not embedded in domain skills.

11. **Metadata as CKE (dual-layer)**: Document type specs are treated as a Cortex Knowledge Extension — dynamically discoverable via Cortex Search rather than enforced as a rigid config table schema. Two CKE layers serve different consumers: the **Schema CKE** (`CLINICAL_DOCS_MODEL_SEARCH_SVC`, auto-generated by `GENERATE_DYNAMIC_OBJECTS()` Step 7) answers "what tables/columns exist?", while the optional **Spec CKE** (`CLINICAL_DOCS_SPECS_SEARCH_SVC`, loaded from `document_type_specs.yaml`) answers "what fields should I extract from a discharge summary?". This follows the pattern established by DICOM's `data-model-knowledge` sub-skill. See `references/metadata_as_cke.md` for details.

## Snowflake Objects Created

| Object Type | Count | Schema | Details |
|------------|-------|--------|---------|
| Tables | 8 | {schema} | CLINICAL_DOCS_EXTRACTION_CONFIG, DOCUMENT_HIERARCHY, DOCS_PARSE_OUTPUT, DOC_CLASSIFICATION_METADATA_ROWS, DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT, CLINICAL_DOCUMENTS_RAW_CONTENT, DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG, DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG |
| Tables | 1 | DATA_MODEL_KNOWLEDGE | CLINICAL_DOCS_MODEL_REFERENCE |
| Tables | 1 (optional) | DATA_MODEL_KNOWLEDGE | CLINICAL_DOCS_SPECS_REFERENCE (loaded from document_type_specs.yaml) |
| Views | Auto-generated pivot views + MRN_PATIENT_MAPPING (auto-grows with doc types) | {schema} | One pivot view per doc type with a VIEW_NAME in extraction config |
| UDFs | 3 | {schema} | BUILD_DOCUMENT_CLASIFICATION_EXTRACTION_JSON, BUILD_DOC_TYPE_EXTRACTION_JSON, INJECT_IMAGE_DESCRIPTIONS |
| Stored Procedures | 7 | {schema} | GENERATE_DYNAMIC_OBJECTS + 6 pipeline procs (modular `proc_*.sql` files) |
| Stream | 1 | {schema} | DOCS_PARSE_OUTPUT_STREAM (APPEND_ONLY) |
| Task | 1 | {schema} | REFRESH_RAW_CONTENT_TASK (99-hour schedule, stream-triggered) |
| Stage | 1 | {schema} | INTERNAL_CLINICAL_DOCS_STAGE |
| Semantic View | 1 | {schema} | CLINICAL_DOCS_SEMANTIC_VIEW (dynamically generated) |
| Cortex Search Service | 1 | {schema} | CLINICAL_DOCS_SEARCH_SERVICE (created by clinical-docs-search sub-skill) |
| Cortex Search Service | 1 | DATA_MODEL_KNOWLEDGE | CLINICAL_DOCS_MODEL_SEARCH_SVC (Schema CKE — auto-generated schema metadata) |
| Cortex Search Service | 1 (optional) | DATA_MODEL_KNOWLEDGE | CLINICAL_DOCS_SPECS_SEARCH_SVC (Spec CKE — from document_type_specs.yaml) |
| Agent | 1 | AGENTS | Created by clinical-docs-agent sub-skill |

### Stored Procedures

Each pipeline procedure is defined in its own file under `scripts/proc_*.sql` with `$$` delimiters and `{db}/{schema}` placeholder tokens. Replace tokens with actual values before execution. The legacy monolithic `stored_procedures.sql` is retained for reference only.

| Procedure | Source File | Purpose | AI Function |
|-----------|------------|---------|-------------|
| GENERATE_DYNAMIC_OBJECTS | `dynamic_pipeline_setup.sql` | Creates/refreshes all dynamic objects (7 steps) | — |
| EXTRACT_DOCUMENT_CLASSIFICATION_METADATA | `proc_classify_metadata.sql` | Classify single (non-split) documents | AI_PARSE_DOCUMENT + AI_COMPLETE |
| EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES | `proc_extract_type_specific.sql` | Extract fields from single documents | AI_EXTRACT |
| CLASSIFY_AGGREGATED_DOCUMENTS | `proc_classify_aggregated.sql` | Classify split documents across pages | AI_AGG |
| EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG | `proc_extract_with_ai_agg.sql` | Extract fields from split documents | AI_AGG |
| PREPROCESS_CLINICAL_DOCS | `proc_preprocess_clinical_docs.sql` | Split large PDFs, register all file types | — (PyPDF2) |
| CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2 | `proc_parse_with_images.sql` | Parse documents with OCR/LAYOUT + images | AI_PARSE_DOCUMENT |

## GENERATE_DYNAMIC_OBJECTS() — What It Creates

| Step | Object | Dynamic? |
|------|--------|----------|
| 1   | Seed DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG | From CSV/config |
| 1b  | Update classification question (LISTAGG of all configured types + OTHER) | Fully dynamic |
| 2   | Seed DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG | From CSV/config |
| 3   | Pivot views (one per doc type, using IS_IDENTITY_FIELD) | Fully dynamic |
| 4   | MRN_PATIENT_MAPPING view | Fully dynamic |
| 5   | REFRESH_RAW_CONTENT_TASK (with TEMP_STREAM_SNAPSHOT + dynamic JOINs) | Fully dynamic |
| 6   | CLINICAL_DOCS_SEMANTIC_VIEW | Fully dynamic |
| 7   | DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_MODEL_REFERENCE refresh (Schema CKE) | Fully dynamic |
| 7b  | DATA_MODEL_KNOWLEDGE.CLINICAL_DOCS_SPECS_REFERENCE refresh (Spec CKE) | Fully dynamic |

## Adding a New Document Type

```
1. INSERT config rows into CLINICAL_DOCS_EXTRACTION_CONFIG
2. CALL GENERATE_DYNAMIC_OBJECTS()
   → Updates classification prompt (LISTAGG)
   → Creates new pivot view
   → Rebuilds refresh task with new JOIN
   → Adds to Semantic View
   → Refreshes schema metadata
```
