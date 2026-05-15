---
name: clinical-docs-viewer
parent_skill: hcls-provider-cdata-clinical-docs
description: "Build an interactive clinical document viewer using Streamlit. Delegates to the developing-with-streamlit platform skill for implementation. Provides domain-specific component requirements, SQL queries, and UX patterns for clinical document browsing."
tools: ["snowflake_sql_execute"]
---

# Clinical Documents Viewer

Build an interactive clinical document viewer as a Streamlit application. This skill provides **domain-specific requirements** and **delegates implementation** to the `developing-with-streamlit` platform skill.

## ⛔ MANDATORY INTERACTIVE PROTOCOL

**This skill enforces the Recommend → Confirm → Execute pattern. Every 🛑 MANDATORY STOP requires explicit user confirmation via `ask_user_question` before proceeding. Never skip a stop due to prior context or assumptions. See the parent router SKILL.md for full enforcement rules.**

| Gate | Step | What to Ask |
|------|------|-------------|
| GATE V1 | Step 1 | Viewer capabilities selection |
| GATE V2 | Step 3 | Deployment method |

---

## Step 1: Requirements Gathering

### 🛑 MANDATORY STOP — GATE V1: Capabilities Selection

Use `ask_user_question` to ask: "What capabilities do you need in the document viewer?" Present the options below. **DO NOT assume capabilities or start building without confirmation.**

| Capability | Description | Recommended |
|-----------|-------------|-------------|
| Document browser | Browse by doc type, patient, MRN | Yes |
| PDF preview | Render document pages with presigned URLs | Yes |
| Extraction review | View extracted metadata fields | Yes |
| Search interface | Full-text search via Cortex Search | Optional |
| Agent chat | Natural language Q&A via Cortex Agent | Optional |
| Pipeline control | Run extraction steps from UI | Optional |

**Confirm** selected capabilities before proceeding.

## Step 2: Invoke Platform Skill

**Invoke** the `developing-with-streamlit` skill for Streamlit best practices.

Provide these domain-specific requirements to the platform skill:

### Data Source Queries

```sql
-- Document list with classification
SELECT DISTINCT
    dh.DOCUMENT_RELATIVE_PATH,
    dcm.FIELD_VALUE AS DOCUMENT_CLASSIFICATION,
    dh.DOC_PAGES,
    dh.DOC_SIZE_MB
FROM {db}.{schema}.DOCUMENT_HIERARCHY dh
LEFT JOIN {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
    ON dh.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
    AND dcm.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NULL;

-- Extracted fields for a document
SELECT FIELD_NAME, FIELD_VALUE
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
WHERE DOCUMENT_RELATIVE_PATH = '{selected_doc}'
ORDER BY FIELD_NAME;

-- Page content with presigned URLs
SELECT PAGE_NUMBER_IN_PARENT, PAGE_CONTENT, PRESIGNED_URL
FROM {db}.{schema}.CLINICAL_DOCUMENTS_RAW_CONTENT
WHERE DOCUMENT_RELATIVE_PATH = '{selected_doc}'
ORDER BY PAGE_NUMBER_IN_PARENT;
```

### Component Specifications

1. **Sidebar**: Document type filter (`st.selectbox` on `DOCUMENT_CLASSIFICATION` column), patient name search (text_input), MRN filter
2. **Main area**: Document list (dataframe), selected document detail panel
3. **Detail panel**: Extracted metadata table, page content viewer, PDF iframe/link
4. **Search tab** (if selected): Text input → Cortex Search results with page snippets

### Key UX Patterns

- Use `st.selectbox` for document type filtering
- Use `st.data_editor` for reviewing/editing extraction config
- Use `st.iframe` or `st.link_button` with presigned URLs for PDF viewing
- Use `st.expander` for page-by-page content display
- Presigned URLs expire after 7 days — show URL_GENERATED_AT and warn if stale

## Step 3: Deployment

### 🛑 MANDATORY STOP — GATE V2: Deployment Method

Use `ask_user_question` to ask: "How would you like to deploy the viewer?" Present the options below. **DO NOT default to any deployment method without asking.**

| Option | How |
|--------|-----|
| Local development | `streamlit run app.py` |
| Snowflake Streamlit | Upload to stage, create STREAMLIT object |
| SPCS | **Invoke** the `deploy-to-spcs` skill for container deployment |

For SPCS deployment (required for external network access or compute pools):
**Invoke** the `deploy-to-spcs` skill for container deployment.
