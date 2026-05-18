---
name: clinical-docs-viewer
description: Deploy or open the Streamlit clinical document viewer
---

Deploy or access the Clinical Document Intelligence Streamlit viewer:

1. Read `.deployment/manifest.json` — if missing, inform user to run `/clinical-docs:deploy` first
2. Using `{database}` and `{schema}` from manifest, check if viewer is deployed:
```sql
SHOW STREAMLITS LIKE 'CLINICAL_DOCS_VIEWER' IN SCHEMA {database}.{schema};
```

3. **If viewer exists:** Present the app URL:
   > Viewer is live at:
   > `https://app.snowflake.com/<org>/<account>/#/streamlit-apps/{database}.{schema}.CLINICAL_DOCS_VIEWER`

4. **If viewer does NOT exist:** Offer to deploy it:
   - The pre-built app is in `streamlit/app.py` (5 tabs: Browse, Extraction Review, Search, Agent Chat, Pipeline Status)
   - Deploy with:
   ```bash
   snow streamlit deploy --replace \
       --database {database} \
       --schema {schema} \
       --name CLINICAL_DOCS_VIEWER
   ```
   - Or load `skills/clinical-docs-viewer/SKILL.md` for customization options

After deployment, suggest:
- Open the viewer URL in browser
- `/clinical-docs:status` — check pipeline health
- `/clinical-docs:agent` — query documents via natural language
