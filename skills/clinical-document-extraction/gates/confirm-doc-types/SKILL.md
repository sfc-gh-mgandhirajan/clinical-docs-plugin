---
name: confirm-doc-types
parent_skill: clinical-document-extraction
description: "Tier-1 gate micro-skill. Confirms document types and extraction fields with the user. Returns {configured_types}, {fields_per_type}. Requires {db}, {schema} from confirm-environment gate."
tools: ["snowflake_sql_execute", "ask_user_question"]
---

# Gate: Confirm Document Types

This gate micro-skill confirms document type selection and extraction field configuration with the user. It covers GATE E4 and GATE E5 from the extraction pipeline.

**This skill MUST complete and return before pipeline config or execution.**

## Inputs (from previous gate)

| Parameter | Source |
|-----------|--------|
| `{db}` | confirm-environment |
| `{schema}` | confirm-environment |
| `{stage}` | confirm-environment |

## Outputs (returned to caller)

| Parameter | Example | Description |
|-----------|---------|-------------|
| `{configured_types}` | `['DISCHARGE_SUMMARY', 'PATHOLOGY_REPORT']` | List of confirmed document types |
| `{fields_per_type}` | `{'DISCHARGE_SUMMARY': 6, 'PATHOLOGY_REPORT': 6}` | Field count per type |

---

## 🛑 MANDATORY STOP — GATE E4: Document Type Selection

Use `ask_user_question` to ask: "What type(s) of clinical documents are you working with?"

**DO NOT auto-select based on filenames, prior context, or assumptions.**

**Recommend** defaults:
| Document Type | Default Fields | Status |
|---------------|---------------|--------|
| Discharge Summary | MRN, PATIENT_NAME, ADMISSION_DATE, DISCHARGE_DATE, DISCHARGE_DIAGNOSIS, DISCHARGE_DISPOSITION | Pre-configured |
| Pathology Report | MRN, PATIENT_NAME, COLLECTION_DATE, SPECIMEN_TYPE, PATHOLOGICAL_DIAGNOSIS, TUMOR_SIZE | Pre-configured |
| Radiology Report | MRN, PATIENT_NAME, EXAM_DATE, IMAGING_MODALITY, BODY_PART_EXAMINED, FINDINGS, IMPRESSION | Pre-configured |
| Custom type | User-defined | **Ask** user for type name and fields |

**Confirm** selection: "I'll configure extraction for [selected types]. Shall I proceed?"

### Adding a Custom Document Type

If the user specifies a type not in the defaults:

1. **Ask** user: "What fields should I extract from [custom type] documents? I can also auto-detect fields from a sample document."

2. **Option A — AI auto-detection**: Upload a sample PDF to the stage, then:
   ```sql
   SELECT AI_EXTRACT(
       file => TO_FILE('@{db}.{schema}.{stage}', '{sample_file}'),
       responseFormat => OBJECT_CONSTRUCT('DOCUMENT_CLASSIFICATION', 'How would you classify this document?')
   );
   ```
   **Recommend** extracted fields to user, **confirm** before saving.

3. **Option B — Manual specification**: User provides field names and extraction questions.

4. **Execute** config insertion:
   ```sql
   INSERT INTO {db}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG
       (CONFIG_TYPE, DOC_TYPE, FIELD_NAME, EXTRACTION_QUESTION, TARGET_COLUMN, DATA_TYPE, DISPLAY_ORDER, VIEW_NAME, IS_IDENTITY_FIELD)
   VALUES
       ('EXTRACTION', '{DOC_TYPE}', 'MRN', 'What is the Medical Record Number?', 'MRN', 'VARCHAR(100)', 1, '{VIEW_NAME}', 'MRN'),
       ('EXTRACTION', '{DOC_TYPE}', 'PATIENT_NAME', 'What is the patient full name?', 'PATIENT_NAME', 'VARCHAR(200)', 2, '{VIEW_NAME}', 'PATIENT_NAME'),
       ('EXTRACTION', '{DOC_TYPE}', '{FIELD_NAME}', '{EXTRACTION_QUESTION}', '{TARGET_COLUMN}', '{DATA_TYPE}', {ORDER}, '{VIEW_NAME}', '');
   ```
   Then regenerate dynamic objects:
   ```sql
   CALL {db}.{schema}.GENERATE_DYNAMIC_OBJECTS();
   ```

---

## 🛑 MANDATORY STOP — GATE E5: Extraction Fields Confirmation

For each selected document type, present the current extraction config:

```sql
SELECT DOCUMENT_CLASSIFICATION, FIELD_NAME, EXTRACTION_QUESTION, DATA_TYPE, IS_ACTIVE
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG
WHERE DOCUMENT_CLASSIFICATION ILIKE '{doc_type}'
ORDER BY DISPLAY_ORDER;
```

Use `ask_user_question` to ask: "Here are the fields configured for [doc_type]. Would you like to add, modify, or remove any fields?"

Present as an editable table:
| # | Field Name | Extraction Question | Data Type | Active |
|---|-----------|-------------------|-----------|--------|
| 1 | MRN | What is the Medical Record Number? | VARCHAR(100) | YES |
| 2 | PATIENT_NAME | What is the patient full name? | VARCHAR(200) | YES |
| ... | ... | ... | ... | ... |

**Confirm** final field list before proceeding. **DO NOT skip this review step.**

---

## Return

After both gates complete, return the confirmed types and field counts:

```
GATE COMPLETE: confirm-doc-types
  configured_types: [{type1}, {type2}, ...]
  fields_per_type: {type1: N, type2: M, ...}
```

**DO NOT proceed to pipeline execution. Return to caller.**
