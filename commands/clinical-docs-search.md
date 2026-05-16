---
name: clinical-docs-search
description: Search across clinical documents using Cortex Search
---

Search clinical documents using semantic + keyword search:

1. Read `.deployment/manifest.json` — if missing, inform user to run `/clinical-docs:deploy` first
2. Using `{database}` and `{schema}` from manifest, verify Cortex Search Service:
```sql
SHOW CORTEX SEARCH SERVICES LIKE 'CLINICAL_DOCS_SEARCH_SERVICE' IN SCHEMA {database}.{schema};
```

3. **If service exists:** Ask the user what they want to search for using `ask_user_question`
4. Execute the search:
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{database}.{schema}.CLINICAL_DOCS_SEARCH_SERVICE',
    '{"query": "<user_query>", "columns": ["page_content", "patient_name", "document_classification", "document_relative_path"], "limit": 5}'
);
```
5. Present results with document context (classification, patient, relevant text snippet)

6. **If service does NOT exist:** Offer to create it:
   - Load `skills/clinical-docs-search/SKILL.md`
   - Or create directly:
```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE {database}.{schema}.CLINICAL_DOCS_SEARCH_SERVICE
    ON page_content
    ATTRIBUTES patient_name, mrn, document_relative_path, document_classification
    WAREHOUSE = {warehouse}
    TARGET_LAG = '1 hour'
AS (
    SELECT page_content, patient_name, mrn, document_relative_path, document_classification
    FROM {database}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT
);
```

After search, suggest next steps:
- "Refine your search" — allow follow-up queries
- "Ask the Cortex Agent" — for structured questions (e.g., "which patients had readmissions?")
- `/clinical-docs:status` — check overall pipeline health
