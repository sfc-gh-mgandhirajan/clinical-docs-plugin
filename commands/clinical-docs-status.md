---
name: clinical-docs-status
description: Check Clinical Document Intelligence plugin health and pipeline status
---

Check the pipeline health and task DAG status:

1. Read `.deployment/manifest.json` — if missing, inform user to run `/clinical-docs:deploy` first
2. Using `{database}` and `{schema}` from manifest, query pipeline statistics:

```sql
SELECT 'Documents Registered' AS metric, COUNT(*) AS value FROM {database}.{schema}.DOCUMENT_HIERARCHY
UNION ALL
SELECT 'Documents Classified', COUNT(DISTINCT DOCUMENT_RELATIVE_PATH) FROM {database}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
UNION ALL
SELECT 'Fields Extracted', COUNT(*) FROM {database}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
UNION ALL
SELECT 'Pages Parsed', COUNT(*) FROM {database}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT;
```

3. Report task DAG health:
```sql
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
))
WHERE DATABASE_NAME = '{database}' AND SCHEMA_NAME = '{schema}'
ORDER BY SCHEDULED_TIME DESC
LIMIT 10;
```

4. Report classification distribution:
```sql
SELECT FIELD_VALUE AS DOC_TYPE, COUNT(*) AS DOC_COUNT
FROM {database}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
GROUP BY FIELD_VALUE ORDER BY DOC_COUNT DESC;
```

5. Present results as a status dashboard

After status check, suggest next steps:
- If pipeline never ran: "Run `/clinical-docs:deploy` to set up infrastructure"
- If pipeline ran but 0 docs: "Upload documents to stage, then task DAG will process automatically"
- If pipeline active: "Pipeline healthy. Use `/clinical-docs:search` to search or ask the Cortex Agent"
