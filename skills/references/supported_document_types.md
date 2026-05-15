# Supported Document Types

## Pre-Configured Types

| Document Type | Classification Value | Extraction Fields | Pivot View |
|---------------|---------------------|-------------------|------------|
| Discharge Summary | `DISCHARGE SUMMARY` | MRN, PATIENT_NAME, ADMISSION_DATE, DISCHARGE_DATE, DISCHARGE_DIAGNOSIS, DISCHARGE_DISPOSITION | `DISCHARGE_SUMMARY_V` |
| Pathology Report | `PATHOLOGY REPORT` | MRN, PATIENT_NAME, COLLECTION_DATE, SPECIMEN_TYPE, PATHOLOGICAL_DIAGNOSIS, TUMOR_SIZE | `PATHOLOGY_REPORTS_V` |
| Radiology Report | `RADIOLOGY REPORT` | MRN, PATIENT_NAME, EXAM_DATE, IMAGING_MODALITY, BODY_PART_EXAMINED, FINDINGS, IMPRESSION | `RADIOLOGY_REPORTS_V` |

## Adding a New Document Type

### Preferred: Edit the Spec File

The authoritative source for doc type definitions is `references/document_type_specs.yaml`. To add a new type:

1. Add a new entry to `document_type_specs.yaml` following the existing pattern
2. Seed the config table from the spec (generate INSERT SQL from the YAML fields)
3. `CALL GENERATE_DYNAMIC_OBJECTS()`

See `references/metadata_as_cke.md` for the full CKE-driven flow.

### Alternative: Direct SQL INSERT

If you prefer to work directly with the config table, insert rows into `CLINICAL_DOCS_EXTRACTION_CONFIG`. Each row defines one extraction field. Mark identity fields with `IS_IDENTITY_FIELD`:

```sql
INSERT INTO {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG
    (CONFIG_TYPE, DOC_TYPE, FIELD_NAME, EXTRACTION_QUESTION, TARGET_COLUMN, DATA_TYPE, DISPLAY_ORDER, VIEW_NAME, IS_IDENTITY_FIELD)
VALUES
    ('EXTRACTION', 'OPERATIVE NOTE', 'MRN', 'What is the Medical Record Number?', 'MRN', 'VARCHAR(100)', 1, 'OPERATIVE_NOTES_V', 'MRN'),
    ('EXTRACTION', 'OPERATIVE NOTE', 'PATIENT_NAME', 'What is the patient full name?', 'PATIENT_NAME', 'VARCHAR(200)', 2, 'OPERATIVE_NOTES_V', 'PATIENT_NAME'),
    ('EXTRACTION', 'OPERATIVE NOTE', 'SURGERY_DATE', 'When was the surgery performed?', 'SURGERY_DATE', 'VARCHAR(100)', 3, 'OPERATIVE_NOTES_V', ''),
    ('EXTRACTION', 'OPERATIVE NOTE', 'PROCEDURE_NAME', 'What procedure was performed?', 'PROCEDURE_NAME', 'VARCHAR(500)', 4, 'OPERATIVE_NOTES_V', ''),
    ('EXTRACTION', 'OPERATIVE NOTE', 'SURGEON_NAME', 'Who was the primary surgeon?', 'SURGEON_NAME', 'VARCHAR(200)', 5, 'OPERATIVE_NOTES_V', '');
```

### Regenerate all dynamic objects (one command)

```sql
CALL {db}.{schema}.GENERATE_DYNAMIC_OBJECTS();
```

This single call:
- Updates the classification question to include the new type (LISTAGG)
- Seeds the type-specific extraction config
- Creates the new pivot view (`OPERATIVE_NOTES_V`)
- Regenerates the refresh task with JOINs to the new view
- Recreates the Semantic View including the new pivot view
- Refreshes the model corpus from INFORMATION_SCHEMA

### Done

No manual steps required. Whether you added via spec file or direct SQL, the new type is fully wired into:
- **Classification**: AI_EXTRACT will now classify docs as `OPERATIVE NOTE`
- **Extraction**: Type-specific fields configured
- **Pivot view**: Structured columnar access via `OPERATIVE_NOTES_V`
- **Refresh task**: Identity field resolution (MRN/PATIENT_NAME) from new view
- **Semantic View**: Natural language queries via Agent
- **Model knowledge**: Schema awareness via auto-refreshed corpus

## Candidate Document Types for Future Expansion

Pre-defined candidate specs are included (commented out) in `references/document_type_specs.yaml`. Uncomment and customize when ready.

| Type | Suggested Fields |
|------|-----------------|
| Operative Note | MRN, PATIENT_NAME, SURGERY_DATE, PROCEDURE_NAME, SURGEON_NAME, ANESTHESIA_TYPE |
| Lab Report | MRN, PATIENT_NAME, COLLECTION_DATE, TEST_NAME, RESULT_VALUE, REFERENCE_RANGE, ABNORMAL_FLAG |
| Progress Note | MRN, PATIENT_NAME, NOTE_DATE, CHIEF_COMPLAINT, ASSESSMENT, PLAN |
| Consent Form | MRN, PATIENT_NAME, PROCEDURE_NAME, CONSENT_DATE, WITNESS_NAME |
| Nursing Assessment | MRN, PATIENT_NAME, ASSESSMENT_DATE, VITAL_SIGNS, PAIN_SCORE, NURSING_NOTES |

## Handling Unknown Document Types (OTHER)

The classification prompt always includes `OTHER` as a valid response. This is intentional — it catches document types that don't match any configured extraction type.

### What happens to OTHER documents

| Pipeline Layer | Behavior |
|---------------|----------|
| Classification | Document classified as `OTHER` — stored in `DOC_CLASSIFICATION_METADATA_ROWS` |
| Type-specific extraction | **Skipped** — no matching config in `DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG`. Extraction procs return a WARNING with the count of skipped documents |
| Parsing (AI_PARSE_DOCUMENT) | **Processed normally** — page content is extracted regardless of classification |
| Refresh task | Inserted into `CLINICAL_DOCUMENTS_RAW_CONTENT` with `DOCUMENT_CLASSIFICATION = 'OTHER'` and NULL PATIENT_NAME/MRN |
| Cortex Search | **Searchable** by page content, filterable by `DOCUMENT_CLASSIFICATION = 'OTHER'` |
| Semantic View / Agent | **Not covered** — no pivot view exists for unconfigured types. Agent falls back to content search |

### Onboarding OTHER documents

The extraction SKILL.md Step 4.2c provides an interactive onboarding loop:

1. After classification, the skill detects documents with no extraction config
2. Reports the count and asks if the user wants to configure extraction
3. If yes: samples a document, auto-detects fields via AI, recommends config, confirms with user
4. INSERTs into `CLINICAL_DOCS_EXTRACTION_CONFIG` and calls `GENERATE_DYNAMIC_OBJECTS()`
5. Re-classifies the previously-OTHER documents with the updated type list
6. Loops until no more OTHER documents remain (or user explicitly skips)

This ensures no documents silently fall through the pipeline without user awareness.
