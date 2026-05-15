---
name: clinical-docs-status
description: Check Clinical Document Intelligence plugin health and pipeline status
---

Run the preflight check and report pipeline health:

1. Execute `setup/preflight.py` to verify all prerequisites
2. Query pipeline statistics:

```sql
SELECT 
    'Documents Ingested' AS metric, COUNT(*) AS value FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.RAW_DOCUMENTS
UNION ALL
SELECT 'Documents Classified', COUNT(*) FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.CLASSIFIED_DOCUMENTS
UNION ALL
SELECT 'Fields Extracted', COUNT(*) FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.EXTRACTED_FIELDS
UNION ALL
SELECT 'Sections Parsed', COUNT(*) FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.PARSED_SECTIONS
UNION ALL
SELECT 'Audit Events', COUNT(*) FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.AUDIT_LOG;
```

3. Report freshness (most recent activity):

```sql
SELECT 
    MAX(UPLOAD_TIMESTAMP) AS last_ingestion,
    MAX(CLASSIFICATION_TIMESTAMP) AS last_classification,
    MAX(EXTRACTION_TIMESTAMP) AS last_extraction,
    MAX(PARSE_TIMESTAMP) AS last_parse
FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.RAW_DOCUMENTS r
LEFT JOIN HCLS_CLINICAL_DOCS.CLINICAL_DOCS.CLASSIFIED_DOCUMENTS c ON r.DOC_ID = c.DOC_ID
LEFT JOIN HCLS_CLINICAL_DOCS.CLINICAL_DOCS.EXTRACTED_FIELDS e ON r.DOC_ID = e.DOC_ID
LEFT JOIN HCLS_CLINICAL_DOCS.CLINICAL_DOCS.PARSED_SECTIONS p ON r.DOC_ID = p.DOC_ID;
```

4. Present results as a status dashboard to the user
