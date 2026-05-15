# Clinical Document Intelligence

## What is this?

Clinical Document Intelligence is a Snowflake-native solution that transforms unstructured clinical documents (PDFs, scanned images, DOCX) into structured, searchable, queryable data — automatically, continuously, and with HIPAA-grade governance.

It takes clinical documents like discharge summaries, radiology reports, and pathology reports and:
1. **Classifies** them by document type using AI
2. **Extracts** structured fields (diagnoses, medications, dates, findings) per document type
3. **Parses** full text with layout preservation for search
4. **Makes them queryable** via natural language (Cortex Agent) or semantic search (Cortex Search)
5. **Governs** all patient data with masking, row-access policies, and audit trails

---

## Why this matters in Healthcare

### The Problem

Healthcare organizations generate millions of clinical documents annually. Over 80% of clinical data is trapped in unstructured formats — discharge summaries, radiology reports, pathology results, operative notes, progress notes. This data is:

- **Inaccessible** to analytics, quality reporting, and population health programs
- **Unsearchable** without manual chart review
- **Ungoverned** — PHI exposure risk when documents are shared or queried ad-hoc
- **Static** — no way to automatically process new documents as they arrive

Manual abstraction (hiring nurses/coders to read and code documents) costs $15-25 per document and takes 24-72 hours. At scale, this is unsustainable.

### The Solution

This plugin replaces manual chart abstraction with an AI-powered pipeline that:

| Metric | Manual Process | This Plugin |
|--------|---------------|-------------|
| Cost per document | $15-25 | ~$0.02 |
| Processing time | 24-72 hours | 2-5 minutes |
| Scale | 50-100 docs/day/abstractor | Thousands/hour |
| Consistency | Variable (inter-rater) | Deterministic (config-driven) |
| New document types | Weeks to train staff | Minutes (add YAML config) |
| Governance | Manual audit | Automated (hooks + policies) |

### Use Cases

| Use Case | Who Benefits | What They Get |
|----------|-------------|---------------|
| **Quality Reporting** | Quality teams | Automated extraction of readmission dates, diagnoses, disposition for CMS reporting |
| **Clinical Research** | Research coordinators | Cohort identification from pathology/radiology findings without manual chart review |
| **Revenue Cycle** | HIM/Coding teams | Pre-populated coding fields from discharge summaries |
| **Population Health** | Analytics teams | Structured data from progress notes for risk stratification |
| **Care Coordination** | Care managers | Searchable clinical history across all document types |
| **Compliance/Legal** | Compliance officers | Auditable access to PHI with masking and access controls |

---

## How it works

```
Clinical Documents (PDF, DOCX, Images)
         │
         ▼
┌─────────────────────────────────────────────┐
│  S3/Azure/GCS Bucket (or Snowflake Stage)   │
│  with Directory Table + Auto-Refresh        │
└────────────────────┬────────────────────────┘
                     │ Directory Stream detects new files
                     ▼
┌─────────────────────────────────────────────┐
│  Task DAG (5-step pipeline)                 │
│                                             │
│  1. PREPROCESS — register files, split PDFs │
│  2. CLASSIFY — AI identifies document type  │
│  3. EXTRACT — AI pulls structured fields    │
│  4. PARSE — full-text with layout           │
│  5. REFRESH — materialize into queryable    │
└────────────────────┬────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────┐
│  Queryable Outputs                          │
│                                             │
│  • Pivot views per document type            │
│  • Cortex Search (semantic + keyword)       │
│  • Cortex Agent (natural language queries)  │
│  • Streamlit viewer (browse + annotate)     │
│  • Semantic View (BI/analytics layer)       │
└─────────────────────────────────────────────┘
```

### Key Architecture Decisions

- **Config-driven extraction** — Adding a new document type = add a YAML entry, no code changes
- **Stream + Task DAG** — New documents processed automatically when they land
- **Two-path AI processing** — Single-page docs use AI_EXTRACT directly; multi-page docs use AI_AGG across pages
- **EAV storage with pivot views** — Flexible schema that grows with new document types without migrations
- **Three-layer enforcement** — AGENTS.md + execution_contract + PreToolUse hooks prevent architectural shortcuts

---

## How to Deploy

### Prerequisites

- Snowflake account in a Cortex AI-supported region
- ACCOUNTADMIN or role with: CREATE DATABASE/SCHEMA, CREATE STAGE, CREATE TASK, CREATE MASKING POLICY
- Warehouse MEDIUM or larger
- Clinical documents in S3, Azure Blob, GCS, or Snowflake internal stage

### Deployment (Guided by CoCo)

Run the deploy command in Cortex Code:

```
/clinical-docs:deploy
```

CoCo will guide you through 7 decisions in ~60 seconds:

1. **Target location** — Which database and schema
2. **Document source** — S3 bucket URL, storage integration, auto-refresh
3. **Document types** — Which types you have (multi-select)
4. **Warehouse** — Which warehouse to run the pipeline (with cost estimate)
5. **Governance** — Full HIPAA / masking only / dev mode
6. **Role mapping** — Who sees PHI, who sees masked data
7. **Orchestration** — Stream+Task (auto) / Scheduled / Manual

After approval, CoCo provisions everything and writes a deployment manifest. Future runs skip setup entirely — one confirmation and you're processing documents.

### Post-Deployment

```
/clinical-docs:extract    # Process documents (or automatic if Stream+Task)
/clinical-docs:search     # Enable semantic search
/clinical-docs:status     # Check pipeline health
```

---

## What's in the Plugin

| Component | Purpose |
|-----------|---------|
| `DEPLOY.md` | Guided deployment workflow (probe → decide → provision → manifest) |
| `AGENTS.md` | Enforcement rules — prevents architectural shortcuts |
| `plugin.json` | Manifest with execution_contract + composed skill references |
| `hooks/enforce-contract.sh` | Hard-blocks prohibited SQL patterns (PreToolUse) |
| `hooks/phi-output-guard.sh` | Blocks PHI exposure in outputs (PreToolUse) |
| `hooks/audit-trail.sh` | Logs all DML on PHI tables (PostToolUse) |
| `commands/` | Slash commands: deploy, extract, search, status |
| `config/document_type_specs.yaml` | Document type definitions (authoritative source) |
| `setup/` | Preflight checks, infrastructure SQL, teardown |
| `tests/` | E2E validation with synthetic documents |

### Composed Skills (Domain Logic)

The plugin references skills from the shared `skills/` folder:

| Skill | What It Does |
|-------|-------------|
| `clinical-document-extraction` | 5-phase pipeline: classify → extract → parse (7 procs, 3 UDFs) |
| `clinical-docs-search` | Cortex Search Service over parsed content |
| `clinical-docs-agent` | Cortex Agent combining structured + unstructured queries |
| `clinical-docs-viewer` | Streamlit document browser with extraction highlights |
| `data-model-knowledge` | Schema reference via Cortex Search (self-documenting) |

---

## Snowflake Features Used

| Feature | How It's Used |
|---------|--------------|
| **Cortex AI Functions** | AI_PARSE_DOCUMENT (OCR/layout), AI_EXTRACT (structured fields), AI_AGG (multi-page), AI_COMPLETE (classification) |
| **Cortex Search** | Hybrid semantic + keyword search over clinical content |
| **Cortex Agent** | Natural language queries combining analytics + search |
| **Streams** | Directory stream on stage (detect new files), parse output stream (trigger refresh) |
| **Tasks** | 5-task DAG for end-to-end pipeline orchestration |
| **Masking Policies** | PHI column protection with role-based access |
| **Row-Access Policies** | Document-type scoped access control |
| **Tags** | PHI sensitivity classification (HIGH/MEDIUM/LOW) |
| **Directory Tables** | Catalog files on external stages for structured querying |
| **Storage Integrations** | Secure access to S3/Azure/GCS document repositories |
| **Semantic Views** | Analytics-ready layer for BI tools and Cortex Agent |
| **Streamlit** | Interactive document viewer and annotation UI |

---

## Document Types Supported

Out of the box (configurable via YAML):

| Type | Fields Extracted | Example Use |
|------|-----------------|-------------|
| Discharge Summary | MRN, patient name, admission/discharge dates, diagnoses, disposition, medications | Readmission tracking, transition of care |
| Radiology Report | MRN, modality, body part, findings, impression, recommendations | Incidental finding follow-up |
| Pathology Report | MRN, specimen, diagnosis, margins, staging, molecular markers | Cancer registry, tumor board prep |
| Operative Note | MRN, procedure, surgeon, findings, complications, EBL | Surgical quality metrics |
| Progress Note | MRN, date, assessment, plan, vitals, medications | Longitudinal patient tracking |

Adding a custom type: edit `config/document_type_specs.yaml` and re-run config seeding. No code changes required.

---

## Security and Compliance

| Control | Implementation |
|---------|---------------|
| PHI masking | `IS_ROLE_IN_SESSION()` — only authorized roles see unmasked data |
| Row-level access | Document-type scoped policies |
| Audit trail | All DML on PHI tables logged with timestamp, user, SQL hash |
| Output guard | PreToolUse hook blocks PHI patterns (SSN, MRN, DOB) from leaking to chat |
| Enforcement hooks | Prevents ad-hoc SQL that bypasses stored procedures |
| No PHI in config | Document type specs are field definitions only — no patient data |

---

## License

Proprietary — Snowflake Health Sciences
