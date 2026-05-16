---
name: clinical-docs-extract
description: Run or monitor the clinical document extraction pipeline
---

Process clinical documents through the extraction pipeline:

1. Read `.deployment/manifest.json` — if missing, inform user to run `/clinical-docs:deploy` first
2. Using manifest, determine orchestration mode:

**If orchestration = stream_task or scheduled:**
- The task DAG handles processing automatically. Check status:
```sql
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'CLINICAL_DOCS_PIPELINE_ROOT',
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC LIMIT 5;
```
- If no recent runs and files exist, trigger manually:
```sql
ALTER STAGE @{database}.{schema}.{stage} REFRESH;
EXECUTE TASK {database}.{schema}.CLINICAL_DOCS_PIPELINE_ROOT;
```
- Monitor progress until completion

**If orchestration = manual:**
- Load `skills/SKILL.md` (the router skill)
- The router's Step 0 reads the manifest for fast-path (1 confirm → proceed)
- Then routes to `skills/clinical-document-extraction/SKILL.md` for phased execution

After completion, suggest next steps:
- `/clinical-docs:status` to verify processing results
- If Search not yet created: "Enable semantic search with `/clinical-docs:search`"
- If Agent not yet created: "Create Cortex Agent for natural language queries"
- If Viewer not deployed: "Deploy the Streamlit viewer for interactive browsing"
