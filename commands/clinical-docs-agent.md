---
name: clinical-docs-agent
description: Create or query the Cortex Agent for natural language Q&A over clinical documents
---

Interact with the Clinical Documents Cortex Agent:

1. Read `.deployment/manifest.json` — if missing, inform user to run `/clinical-docs:deploy` first
2. Using `{database}` and `{schema}` from manifest, check if agent exists:
```sql
SHOW CORTEX AGENTS LIKE 'CLINICAL_DOCUMENTS_AGENT' IN SCHEMA {database}.{schema};
```

3. **If agent exists:** Ask the user what they want to know using `ask_user_question`
4. Execute the agent query:
```sql
SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    '{database}.{schema}.CLINICAL_DOCUMENTS_AGENT',
    $$ {"messages": [{"role": "user", "content": [{"type": "text", "text": "<user_question>"}]}]} $$
);
```
5. Parse and present the response (extract text from messages[].content[].text)

6. **If agent does NOT exist:** Offer to create it:
   - Requires: Cortex Search Service (check with `/clinical-docs:search`)
   - Requires: Semantic View over pivot views
   - Load `skills/clinical-docs-agent/SKILL.md` for guided creation

After response, suggest:
- "Ask another question" — allow follow-up
- `/clinical-docs:search` — for direct document search without agent reasoning
- `/clinical-docs:status` — check pipeline health
