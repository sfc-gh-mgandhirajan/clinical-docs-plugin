---
name: clinical-docs-deploy
description: "Guided deployment for Clinical Document Intelligence plugin. Probes environment, collects deployment decisions, provisions infrastructure (including external stage, directory tables, and task DAG orchestration), and writes deployment manifest for fast skill re-use."
tools: ["*"]
---

# Clinical Document Intelligence — Deployment

Deploy the Clinical Document Intelligence pipeline to your Snowflake account. This guided workflow probes your environment, asks key decisions, creates all required objects, and writes a deployment manifest so subsequent skill runs proceed with a single confirmation.

## Prerequisites

- Snowflake account with Cortex AI enabled (AI_PARSE_DOCUMENT, AI_EXTRACT, AI_AGG)
- Role with CREATE DATABASE (or CREATE SCHEMA in existing DB), CREATE STAGE, CREATE MASKING POLICY, CREATE TASK privileges
- Warehouse MEDIUM or larger recommended
- For external stages: storage integration with access to your S3/Azure/GCS bucket

---

## Phase 1: Environment Probe (Auto-Detected)

Run these probes silently — do NOT ask the user for this information:

```sql
SELECT CURRENT_ACCOUNT() AS account, CURRENT_ROLE() AS role, 
       CURRENT_WAREHOUSE() AS warehouse, CURRENT_USER() AS user_name,
       CURRENT_REGION() AS region;
```

```sql
SHOW DATABASES;
```

```sql
SHOW WAREHOUSES;
```

```sql
SHOW STAGES;
```

```sql
SHOW STORAGE INTEGRATIONS;
```

Check Cortex AI availability:
```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic', 'test') AS cortex_test;
```

After all probes complete, present a summary:

> **Environment detected:**
> - Account: {account} ({region})
> - Role: {role}
> - Available warehouses: {list with sizes}
> - Existing databases: {relevant ones}
> - Existing stages with files: {list any containing PDFs/docs}
> - Storage integrations: {list existing, e.g., "S3_INT (AWS)", "AZURE_INT (Azure)"}
> - Cortex AI: Available / Not available

If Cortex AI is NOT available, **STOP** — plugin cannot function without it. Advise the user to check region support.

---

## Phase 2: Deployment Decisions

### 🛑 MANDATORY STOP — Decision 1: Target Location

Use `ask_user_question` to ask where to deploy. Present detected databases as options:

> Where should the pipeline tables be created?

Options based on probed environment:
- Create new database `HCLS_CLINICAL_DOCS` with schema `CLINICAL_DOCS`
- Use existing database `{detected_db}` with new schema `CLINICAL_DOCS`
- Let me specify (text input for database.schema)

Record: `{target_database}`, `{target_schema}`

### 🛑 MANDATORY STOP — Decision 2: Document Source

Use `ask_user_question`:

> Where are your clinical documents (PDFs, DOCX, images)?

Options:
- Create a new internal stage (I'll upload documents later)
- Use existing stage: `{detected_stage_1}` ({file_count} files)
- Use existing stage: `{detected_stage_2}` ({file_count} files)
- External stage (S3/Azure/GCS)

Record: `{stage_type}` (internal | external), `{source_stage}`

### 🛑 MANDATORY STOP — Decision 2b: External Stage Configuration

**Only ask if `{stage_type}` = external.**

Use `ask_user_question` to gather external stage details:

> Configure your external document source:

Questions:
1. **Cloud provider**: AWS S3 / Azure Blob Storage / Google Cloud Storage
2. **URL**: Full path to your documents (e.g., `s3://my-bucket/clinical-docs/`, `azure://container/path/`, `gcs://bucket/path/`)
3. **Storage integration**: 
   - Use existing: `{detected_integration_1}`, `{detected_integration_2}` (from probe)
   - Create new (will need IAM role ARN for AWS, Tenant ID for Azure, or Service Account for GCS)
4. **File types present**: PDF, DOCX, TXT, TIFF, PNG, JPG (multi-select)
5. **Auto-refresh**: Enable cloud event notifications (SNS for AWS, Event Grid for Azure, Pub/Sub for GCS) so new files are detected automatically? (yes/no)

If creating a new storage integration, ask:
- For AWS: `What is the IAM Role ARN that grants access to the S3 bucket?`
- For Azure: `What is the Tenant ID and Consent URL?`
- For GCS: `What is the service account email?`

Record: `{cloud_provider}`, `{stage_url}`, `{storage_integration}`, `{storage_integration_is_new}`, `{file_types}`, `{auto_refresh}`, `{iam_role_arn}` (or equivalent)

### 🛑 MANDATORY STOP — Decision 3: Document Types

Read available types from `config/document_type_specs.yaml` and present as multi-select:

> Which document types do you have? (select all that apply)

Options from YAML:
- Discharge Summaries
- Radiology Reports
- Pathology Reports
- Operative Notes
- Progress Notes
- Add custom type (describe it)

Record: `{selected_document_types}`

### 🛑 MANDATORY STOP — Decision 3b: Customize Extraction Questions

Present guidance on config contextualization:

> **Important:** The extraction quality depends on how well the questions in `config/document_type_specs.yaml` match YOUR documents.
>
> Each document type has a set of `extraction_question` fields that tell the AI what to look for. The defaults are generic — customizing them for your specific document formats dramatically improves accuracy.
>
> **Examples of good customization:**
> | Default Question | Customized for Your Org |
> |---|---|
> | "What is the primary discharge diagnosis?" | "What is the primary ICD-10 discharge diagnosis code and description?" |
> | "What is the discharge disposition?" | "What is the discharge disposition? Include facility name if transferred." |
> | "What are the findings?" | "What are the radiological findings? Include laterality and measurements." |
>
> **How to customize:** Edit `config/document_type_specs.yaml` — each entry has:
> - `field_name`: Column name in the output table
> - `extraction_question`: The prompt given to AI (this is what you customize)
> - `data_type`: Expected output format
>
> What would you like to do?

Options:
- **Use defaults now, customize later** (recommended for first deployment — see results, then refine)
- **Review and edit the config file now** (opens document_type_specs.yaml for editing)
- **Upload a sample document** so CoCo can suggest better extraction questions based on your actual content

If "Review and edit":
- Open `config/document_type_specs.yaml` and walk through the fields for each selected doc type
- Explain the structure and let the user modify extraction_question values

If "Upload a sample":
- Parse ONE document with AI_PARSE_DOCUMENT
- Present the content summary
- Suggest tailored extraction questions based on what's in the document
- Update the YAML with user-approved questions

Record: `{config_customized}` (defaults | edited | sample-guided)

### 🛑 MANDATORY STOP — Decision 4: Warehouse Selection

Present detected warehouses with cost context:

> Which warehouse should run the pipeline?

Options:
- `{warehouse_1}` (SIZE: {size}) — estimated ~${cost} for {doc_count} documents
- `{warehouse_2}` (SIZE: {size}) — estimated ~${cost} for {doc_count} documents

Cost estimate formula: ~$0.02 per document on MEDIUM warehouse (AI_PARSE + AI_EXTRACT + AI_COMPLETE).

Record: `{deploy_warehouse}`

### 🛑 MANDATORY STOP — Decision 5: Governance Posture

> What level of data governance do you need?

Options:
- **Full HIPAA** — PHI masking policies, row-access policies, audit trail, PHI output guard hook (recommended for production)
- **Masking only** — PHI columns masked by default, no row-access policies
- **Dev/exploration** — No governance (for testing with synthetic data only)

Record: `{governance_posture}`

### 🛑 MANDATORY STOP — Decision 6: Role Mapping

Only ask if governance_posture is NOT "dev/exploration":

> Map your organization's roles to pipeline roles:

- Who gets **full PHI access** (can see unmasked patient data)? → text input, default: `{current_role}`
- Who gets **read-only/masked** access? → text input, default: suggest common analyst role
- Who **administers** this pipeline? → text input, default: `{current_role}`

Record: `{role_admin}`, `{role_phi_access}`, `{role_viewer}`

### 🛑 MANDATORY STOP — Decision 7: Pipeline Orchestration

> How should new documents be processed when they arrive?

Options:
- **Stream + Task DAG** (recommended for production) — A directory stream detects new files on stage. A 5-task DAG runs automatically: preprocess → classify → extract → parse → refresh. Near-real-time processing.
- **Scheduled Task DAG** — Same task chain but triggered on a fixed schedule instead of by new files. Best for predictable batch workloads.
- **Manual / On-Demand** — No automated processing. Run `/clinical-docs:extract` when ready. Best for dev/test or one-time batch.

If "Scheduled Task DAG" selected, follow up:

> How often should the pipeline run?

Options:
- Every hour
- Every 6 hours
- Daily (midnight UTC)
- Custom (text input for CRON expression)

Record: `{orchestration_mode}` (stream_task | scheduled | manual), `{schedule_interval}` (if scheduled)

---

## Phase 3: Provision Infrastructure

Present a deployment plan summary before executing:

> **Deployment Plan:**
> 1. Create schema `{target_database}.{target_schema}`
> 2. Configure stage: {stage_type} ({stage_url or 'internal'})
> 3. Enable directory table + verify file access
> 4. Create pipeline tables (8 tables + audit)
> 5. Create config table + seed with {N} document types
> 6. Create 7 stored procedures + 3 UDFs
> 7. Apply governance: {governance_posture}
> 8. Set up orchestration: {orchestration_mode}
> 9. Write deployment manifest
>
> Approve?

### 🛑 MANDATORY STOP — Approve Deployment

Use `ask_user_question` with Approve / Modify / Cancel options.

### Execute Deployment

On approval, execute in order:

---

**Step 1: Schema + Stage**

```sql
CREATE DATABASE IF NOT EXISTS {target_database};
CREATE SCHEMA IF NOT EXISTS {target_database}.{target_schema};
USE DATABASE {target_database};
USE SCHEMA {target_schema};
```

If `{stage_type}` = internal:
```sql
CREATE STAGE IF NOT EXISTS {source_stage}
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

If `{stage_type}` = external AND `{storage_integration_is_new}` = true:
```sql
CREATE STORAGE INTEGRATION {storage_integration}
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = '{cloud_provider}'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('{stage_url}')
    -- AWS: STORAGE_AWS_ROLE_ARN = '{iam_role_arn}'
    -- Azure: AZURE_TENANT_ID = '{tenant_id}'
    ;

-- Show integration details for trust policy setup
DESC STORAGE INTEGRATION {storage_integration};
```

If external (new or existing integration):
```sql
CREATE STAGE IF NOT EXISTS {source_stage}
    STORAGE_INTEGRATION = {storage_integration}
    URL = '{stage_url}'
    DIRECTORY = (ENABLE = TRUE, AUTO_REFRESH = {auto_refresh})
    FILE_FORMAT = (TYPE = 'CSV' PARSE_HEADER = FALSE);  -- generic, files read as binary by AI_PARSE
```

---

**Step 2: Directory Table Verification**

```sql
ALTER STAGE @{target_database}.{target_schema}.{source_stage} REFRESH;
```

```sql
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DIRECTORY(@{target_database}.{target_schema}.{source_stage})
LIMIT 20;
```

Present results:
> **Directory table active**: {N} files detected
> - File types: {breakdown, e.g., "234 PDF, 89 DOCX, 12 PNG"}
> - Total size: {sum}
> - Latest file: {most_recent_date}

If 0 files detected:
- If external stage: WARN — "No files found. Check that the storage integration has read access to `{stage_url}`. You may need to update the IAM trust policy with the external ID from DESC STORAGE INTEGRATION."
- If internal stage: INFO — "Stage is empty. Upload documents later using PUT or the Snowsight UI."

**Do NOT block deployment** if 0 files — continue, as files may arrive after deployment.

---

**Step 3: Pipeline Tables + Stored Procedures**

Execute the infrastructure script from the composed skill:
- File: `skills/clinical-document-extraction/scripts/dynamic_pipeline_setup.sql`
- Set parameters: `$V_DB = '{target_database}'`, `$V_SCHEMA = '{target_schema}'`, `$V_STAGE = '{source_stage}'`, `$V_WAREHOUSE = '{deploy_warehouse}'`

This creates:
- 8 pipeline tables (DOCUMENT_HIERARCHY, DOCS_PARSE_OUTPUT, DOC_CLASSIFICATION_METADATA_ROWS, DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT, CLINICAL_DOCUMENTS_RAW_CONTENT, CLINICAL_DOCS_EXTRACTION_CONFIG, DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG, DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG)
- 3 UDFs (BUILD_DOCUMENT_CLASIFICATION_EXTRACTION_JSON, BUILD_DOC_TYPE_EXTRACTION_JSON, INJECT_IMAGE_DESCRIPTIONS)
- 1 Stream (DOCS_PARSE_OUTPUT_STREAM)
- 1 Task (REFRESH_RAW_CONTENT_TASK — standalone refresh, used by DAG or directly)

Then execute each proc script from the composed skill (in order):
1. `proc_preprocess_clinical_docs.sql`
2. `proc_classify_metadata.sql`
3. `proc_classify_aggregated.sql`
4. `proc_extract_type_specific.sql`
5. `proc_extract_with_ai_agg.sql`
6. `proc_parse_with_images.sql`

---

**Step 4: Config Seeding**

Read `config/document_type_specs.yaml`, filter to `{selected_document_types}`, INSERT into `CLINICAL_DOCS_EXTRACTION_CONFIG`.

Then run:
```sql
CALL {target_database}.{target_schema}.GENERATE_DYNAMIC_OBJECTS();
```

This generates pivot views, the semantic view, and CKE metadata tables based on the seeded config.

---

**Step 5: Governance (conditional)**

If `{governance_posture}` = "full_hipaa" or "masking_only":
```sql
CREATE MASKING POLICY IF NOT EXISTS {target_database}.{target_schema}.PHI_TEXT_MASK 
    AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN IS_ROLE_IN_SESSION('{role_phi_access}') THEN val
        WHEN IS_ROLE_IN_SESSION('{role_admin}') THEN val
        ELSE '*** PHI MASKED ***'
    END;

ALTER TABLE {target_database}.{target_schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
    MODIFY COLUMN FIELD_VALUE SET MASKING POLICY {target_database}.{target_schema}.PHI_TEXT_MASK;

ALTER TABLE {target_database}.{target_schema}.CLINICAL_DOCUMENTS_RAW_CONTENT
    MODIFY COLUMN PAGE_CONTENT SET MASKING POLICY {target_database}.{target_schema}.PHI_TEXT_MASK;
```

If `{governance_posture}` = "full_hipaa":
- Create row-access policy scoped by document type
- Create AUDIT_LOG table
- Apply PHI tags (PHI_LEVEL = 'HIGH' on patient-data columns)
- Apply MRN/PATIENT_NAME masking to pivot views

---

**Step 6: Pipeline Orchestration (conditional)**

If `{orchestration_mode}` = "stream_task":
Execute orchestration script from the composed skill:
- File: `skills/clinical-document-extraction/scripts/pipeline_orchestration.sql`
- Set parameters:
  - `$V_DB = '{target_database}'`
  - `$V_SCHEMA = '{target_schema}'`
  - `$V_STAGE = '{source_stage}'`
  - `$V_WAREHOUSE = '{deploy_warehouse}'`
  - `$V_MODE = 'stream'`
  - `$V_SCHEDULE = NULL`

If `{orchestration_mode}` = "scheduled":
Same script with:
  - `$V_MODE = 'schedule'`
  - `$V_SCHEDULE = '{schedule_interval}'` (e.g., '1 HOUR', 'USING CRON 0 0 * * * UTC')

If `{orchestration_mode}` = "manual":
- Skip orchestration setup
- The standalone REFRESH_RAW_CONTENT_TASK (from Step 3) remains available for manual `EXECUTE TASK` calls
- User will run `/clinical-docs:extract` to trigger the pipeline manually

After orchestration setup, verify:
```sql
SHOW TASKS IN SCHEMA {target_database}.{target_schema};
```

Present: "Task DAG active: {N} tasks, root task status: STARTED"

**If files already exist on stage AND orchestration is stream_task or scheduled:**

Trigger the first pipeline run by refreshing the directory table (generates stream data):
```sql
ALTER STAGE @{target_database}.{target_schema}.{source_stage} REFRESH;
```

Then monitor progress (poll every 30 seconds, up to 10 minutes):
```sql
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'CLINICAL_DOCS_PIPELINE_ROOT',
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC
LIMIT 5;
```

Present progress:
> Pipeline triggered. Monitoring task DAG execution...
> - ROOT (preprocess): {status}
> - CLASSIFY: {status}
> - EXTRACT: {status}
> - PARSE: {status}
> - REFRESH: {status}
>
> {N} documents processed successfully.

**Do NOT call stored procedures manually.** The task DAG handles execution order and dependencies.

If any task fails, present the error and suggest:
- Check warehouse is active: `ALTER WAREHOUSE {warehouse} RESUME;`
- Check task history for details
- Re-trigger: `EXECUTE TASK {target_database}.{target_schema}.CLINICAL_DOCS_PIPELINE_ROOT;`

---

**Step 7: Write Deployment Manifest**

After all steps succeed, write `.deployment/manifest.json` to the plugin workspace:

```json
{
  "plugin": "clinical-document-intelligence",
  "version": "1.0.0",
  "deployed_at": "{timestamp}",
  "deployed_by": "{current_user}",
  "connection": "{connection_name}",
  "account": "{account}",
  "environment": {
    "database": "{target_database}",
    "schema": "{target_schema}",
    "stage": "{source_stage}",
    "warehouse": "{deploy_warehouse}"
  },
  "stage_config": {
    "type": "{stage_type}",
    "cloud_provider": "{cloud_provider}",
    "url": "{stage_url}",
    "storage_integration": "{storage_integration}",
    "directory_enabled": true,
    "auto_refresh": "{auto_refresh}"
  },
  "document_types": ["{selected_document_types}"],
  "governance_posture": "{governance_posture}",
  "roles": {
    "admin": "{role_admin}",
    "phi_access": "{role_phi_access}",
    "viewer": "{role_viewer}"
  },
  "orchestration": {
    "mode": "{orchestration_mode}",
    "root_task": "CLINICAL_DOCS_PIPELINE_ROOT",
    "schedule": "{schedule_interval}",
    "task_count": 5
  }
}
```

Write this file to: `.deployment/manifest.json`

---

## Phase 4: Post-Pipeline Capabilities

After the extraction pipeline has processed documents successfully, offer additional capabilities:

### 🛑 MANDATORY STOP — Decision 8: Additional Capabilities

> Your extraction pipeline is running. What additional capabilities do you want to enable?

Options (multi-select):
- **Cortex Search Service** — Semantic + keyword search over document content (recommended)
- **Cortex Agent** — Natural language Q&A combining structured queries + full-text search (requires Search)
- **Streamlit Viewer** — Interactive document browser with extraction review, search, and agent chat
- **Skip for now** — Can add these later

Record: `{post_pipeline_capabilities}`

### If Cortex Search selected:

Execute the search service creation (from `skills/clinical-docs-search/SKILL.md`):
```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE {target_database}.{target_schema}.CLINICAL_DOCS_SEARCH_SERVICE
    ON page_content
    ATTRIBUTES patient_name, mrn, document_relative_path, document_classification
    WAREHOUSE = {deploy_warehouse}
    TARGET_LAG = '1 hour'
AS (
    SELECT page_content, patient_name, mrn, document_relative_path, document_classification
    FROM {target_database}.{target_schema}.CLINICAL_DOCUMENTS_RAW_CONTENT
);
```

Verify: `SHOW CORTEX SEARCH SERVICES IN SCHEMA {target_database}.{target_schema};`

### If Cortex Agent selected (requires Search):

1. Create Semantic View (from `skills/clinical-docs-agent/SKILL.md` Step 1):
   - Build semantic view over all pivot views + MRN_PATIENT_MAPPING
   - Include dimensions with SYNONYMS for discoverability
   - Include metrics (patient count, document counts per type)

2. Create Cortex Agent (from `skills/clinical-docs-agent/SKILL.md` Step 2):
```sql
CREATE OR REPLACE CORTEX AGENT {target_database}.{target_schema}.CLINICAL_DOCUMENTS_AGENT
    TOOLS = (
        CORTEX_ANALYST_TOOL('{target_database}.{target_schema}.CLINICAL_DOCS_SEMANTIC_VIEW') AS CLINICAL_DOCS_ANALYST,
        CORTEX_SEARCH_TOOL('{target_database}.{target_schema}.CLINICAL_DOCS_SEARCH_SERVICE', 'page_content') AS CLINICAL_DOCS_SEARCH
    );
```

3. Test with sample query to verify both tools work.

### If Streamlit Viewer selected:

Deploy the pre-built viewer app from `streamlit/`:
```bash
snow streamlit deploy --replace \
    --database {target_database} \
    --schema {target_schema} \
    --name CLINICAL_DOCS_VIEWER
```

The app is pre-built with 5 tabs (Browse, Extraction Review, Search, Agent Chat, Pipeline Status) and is SiS-compatible (Streamlit 1.22).

---

## Phase 5: Confirmation

Present final status:

> **Deployment complete!**
>
> | Object | Count |
> |--------|-------|
> | Tables | 8 + audit |
> | Stored Procedures | 7 |
> | UDFs | 3 |
> | Policies | {N based on governance} |
> | Config entries | {N doc types} |
> | Directory table | enabled |
> | Stream | {1 if orchestration != manual, else 0} (directory) |
> | Task DAG | {5 if orchestration != manual, else 1} tasks |
>
> **Orchestration**: {orchestration_mode description}
> - Stream-triggered: new files processed automatically when they land
> - Scheduled: pipeline runs {schedule_interval}
> - Manual: run `/clinical-docs:extract` to process
>
> **Next steps:**
> - {If 0 files} Upload documents to `@{target_database}.{target_schema}.{source_stage}`
> - {If files exist + manual} Run `/clinical-docs:extract` to process {N} documents
> - {If files exist + automated} Documents will be processed automatically. Monitor with `/clinical-docs:status`
> - Run `/clinical-docs:status` to check pipeline health and task history
>
> Manifest written to `.deployment/manifest.json` — future skill runs will use this for fast startup.

---

## Re-Deployment

If `.deployment/manifest.json` already exists when `/deploy` is run:

1. Read existing manifest
2. Present: "This plugin was deployed on {date} to {database}.{schema}. What would you like to do?"
   - **Re-deploy** (drop and recreate everything)
   - **Update config** (add/remove document types, change governance, change orchestration)
   - **Deploy to different target** (new db/schema, keeps old deployment)
   - **Suspend orchestration** (pause task DAG without dropping)
   - **Cancel**

If "Suspend orchestration":
```sql
ALTER TASK {target_database}.{target_schema}.CLINICAL_DOCS_PIPELINE_ROOT SUSPEND;
```
