---
name: clinical-docs-search
description: Quick semantic search across all extracted clinical documents
---

Search across clinical documents using Cortex Search:

1. Verify the Cortex Search Service exists:
```sql
SHOW CORTEX SEARCH SERVICES IN SCHEMA HCLS_CLINICAL_DOCS.CLINICAL_DOCS;
```

2. If it exists, ask the user what they want to search for using `ask_user_question`

3. Execute the search:
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'HCLS_CLINICAL_DOCS.CLINICAL_DOCS.CLINICAL_DOCS_SEARCH_SVC',
    '{"query": "<user_query>", "columns": ["DOC_ID", "SECTION_NAME", "SEARCH_TEXT"], "limit": 10}'
);
```

4. Present results in a readable format with document context

5. If the service does NOT exist, offer to create it:
   - Load `skills/clinical-docs-search/SKILL.md`
   - Follow the search service creation workflow
