---
name: clinical-docs
description: "Router for clinical document intelligence on Snowflake with defense-in-depth guardrails. Detects intent and routes to sub-skills using phased orchestration with mandatory re-entry between phases. Triggers: clinical document, document extraction, PDF extraction, discharge summary, pathology report, radiology report, clinical docs, AI_PARSE_DOCUMENT, AI_COMPLETE, AI_EXTRACT, AI_AGG, document classification, document pipeline, clinical search, clinical agent."
tools: ["*"]
platform_affinities:
  produces: [tables, stages, cortex_search_service]
  benefits_from:
    - skill: cortex-ai-functions
      when: "using AI_PARSE_DOCUMENT, AI_COMPLETE, AI_EXTRACT, AI_AGG for document processing"
    - skill: data-governance
      when: "clinical documents contain PHI (patient names, MRNs, diagnoses)"
    - skill: search-optimization
      when: "user needs semantic search over extracted clinical document content"
    - skill: developing-with-streamlit
      when: "user wants a document viewer, annotation UI, or extraction dashboard"
    - skill: cortex-agent
      when: "user wants a conversational agent over clinical documents"
---

# Clinical Documents Activation

Route clinical document requests to the appropriate sub-skill with **defense-in-depth guardrail enforcement**.

## Architecture: Defense-in-Depth

This V2 skill uses three layers of guardrail enforcement:

| Layer | Mechanism | Enforcement |
|-------|-----------|-------------|
| 1 | `AGENTS.md` (project root) | Profile-level rules in every session |
| 2 | Gate micro-skills + Phase skills | Structural decomposition — model cannot skip |
| 3 | `hooks.json` | Hard blocks on DDL/DML without prior confirmation |

## ⛔ MANDATORY INTERACTIVE PROTOCOL

**This skill enforces the Recommend → Confirm → Execute pattern. Every decision point marked with 🛑 MANDATORY STOP requires explicit user confirmation before proceeding.**

### Rules (non-negotiable):

1. **NEVER skip a 🛑 MANDATORY STOP** — even if you have prior context, memory files, or the user's intent seems obvious.
2. **NEVER use information from memory files or prior conversations to bypass a decision point.** Always ask the user to confirm.
3. **Every 🛑 MANDATORY STOP must use the `ask_user_question` tool** — do NOT embed questions in prose text.
4. **Wait for the user's response** before executing any SQL or proceeding.
5. **Do NOT batch multiple stops into one question.**
6. **Report results after each execution step** before moving to the next stop.

## When to Use

Activate this skill when the user asks about:

- **Extraction**: "extract", "parse", "pipeline", "classify documents", "ingest", "process documents", "discharge summary", "pathology report", "radiology report"
- **Search**: "search documents", "find in documents", "Cortex Search"
- **Agent**: "agent", "natural language query", "Cortex Agent", "semantic view"
- **Viewer**: "viewer", "dashboard", "Streamlit", "browse documents"
- **Model knowledge**: "data model", "schema", "table structure", "column info"

---

## Step 0: Deployment Manifest Check (Fast Path)

Before running full gates, check if a deployment manifest exists from a prior `/clinical-docs:deploy` run.

**Check for file:** `.deployment/manifest.json` in the plugin workspace root (`.deployment/manifest.json`)

**If manifest EXISTS:**

1. Read `environment.database`, `environment.schema`, `environment.stage`, `environment.warehouse` from the manifest
2. Run a verification probe:
```sql
SELECT COUNT(*) AS config_rows FROM {database}.{schema}.CLINICAL_DOCS_EXTRACTION_CONFIG;
```
3. If probe succeeds (config_rows > 0):
   - Set `{db}` = manifest.database, `{schema}` = manifest.schema, `{stage}` = manifest.stage, `{warehouse}` = manifest.warehouse
   - Use `ask_user_question` with ONE confirmation: "Using {db}.{schema} on {warehouse} ({config_rows} document types configured). Proceed?"
   - If confirmed → **SKIP Gates 1 and 2**, go directly to Step 2 (Route to Sub-skill)
   - If user wants to change → fall through to full Gates 1 + 2 below
4. If probe fails (table missing or empty):
   - Present: "Deployment manifest found but environment appears incomplete. Run `/clinical-docs:deploy` to fix, or continue with manual setup?"
   - If deploy → direct user to run `/clinical-docs:deploy`
   - If manual → fall through to full Gates 1 + 2 below

**If manifest DOES NOT EXIST:**

Continue to Step 1 (full gate interrogation) below.

---

## Step 1: Verify Connection Context

### 🛑 MANDATORY STOP — GATE 1: Connection & Warehouse Verification

Run the connection check:
```sql
SELECT CURRENT_ACCOUNT() AS account, CURRENT_ROLE() AS role, CURRENT_WAREHOUSE() AS warehouse, CURRENT_USER() AS user_name;
```

Use `ask_user_question` to confirm. Present detected account, role, and warehouse as defaults, **plus an explicit option to change the warehouse**. **DO NOT PROCEED** until confirmed.

If user wants a different warehouse:
```sql
SHOW WAREHOUSES;
```

### 🛑 MANDATORY STOP — GATE 2: Database, Schema & Stage Selection

Use `ask_user_question` to ask which database, schema, and stage to use.

**Recommend** defaults:
| Parameter | Default | Description |
|---|---|---|
| `{db}` | `HCLS_COCO_TEST_DB` | Target database |
| `{schema}` | `CLINICAL_DOCS_ACTIVATION` | Target schema |
| `{stage}` | `INTERNAL_CLINICAL_DOCS_STAGE` | Internal stage for source documents |

**DO NOT PROCEED** until explicitly confirmed.

Pass `{db}`, `{schema}`, `{stage}`, `{account}`, `{role}`, `{warehouse}` to all sub-skills.

---

## Step 2: Route to Sub-skill

### 🛑 MANDATORY STOP — GATE 3: Intent Routing

If intent is ambiguous, use `ask_user_question`:

```
Which area can I help you with?

1. Document Extraction — Build the AI-powered extraction pipeline
2. Document Search — Create a Cortex Search Service
3. Clinical Docs Agent — Create a Cortex Agent with structured queries + search
4. Document Viewer — Build a Streamlit document viewer
5. Data Model Knowledge — Explore table structures and schema
```

| Intent | Sub-skill |
|--------|-----------|
| Extract / pipeline / classify | **Phased Extraction Orchestration** (see Step 3 below) |
| Search / full-text / Cortex Search | **Load** `clinical-docs-search/SKILL.md` |
| Agent / analyst / semantic view | **Load** `clinical-docs-agent/SKILL.md` |
| Viewer / dashboard / Streamlit | **Load** `clinical-docs-viewer/SKILL.md` |
| Data model / schema / DDL | **Load** `data-model-knowledge/SKILL.md` |

If the intent spans multiple areas (e.g., "set up the full clinical docs solution"), execute sequentially: extraction → search → agent.

---

## Step 3: Phased Extraction Orchestration

**If intent = extraction**, execute the following phases sequentially. Each phase is a **separate skill load**. The router MUST present phase results to the user and get confirmation before loading the next phase.

### Tier 1: Pre-Condition Gates (must all complete before any pipeline SQL)

| # | Skill to Load | Gates | Returns | Auto-proceed |
|---|--------------|-------|---------|-------------|
| 1 | `clinical-document-extraction/gates/confirm-environment/SKILL.md` | E1 + E2 + E3 | `{db}`, `{schema}`, `{stage}`, `{warehouse}`, `{file_count}` | → next gate |
| 2 | `clinical-document-extraction/gates/confirm-doc-types/SKILL.md` | E4 + E5 | `{configured_types}`, `{fields_per_type}` | → next gate |
| 3 | `clinical-document-extraction/gates/confirm-pipeline-config/SKILL.md` | E6 + E6b + E7 | `{mode}`, `{warehouse_size_decision}`, `{estimated_cost}` | → first phase |

### Tier 2: Pipeline Phases (mandatory re-entry between each)

| # | Skill to Load | Reactive Gates | Re-entry Protocol |
|---|--------------|----------------|-------------------|
| 4 | `clinical-document-extraction/phases/classify/SKILL.md` | E8 (quality) + E9 (unknown type) | **STOP**: Present classification distribution. Use `ask_user_question`: "Classification complete. Proceed to extraction?" |
| 5 | `clinical-document-extraction/phases/extract/SKILL.md` | E10 (quality per type) | **STOP**: Present extraction counts. Use `ask_user_question`: "Extraction complete. Proceed to parse and refresh?" |
| 6 | `clinical-document-extraction/phases/parse-and-refresh/SKILL.md` | None | **STOP**: Present pipeline summary. Use `ask_user_question`: "Pipeline complete! What next?" |

### Re-entry Rules

- After each phase returns, the router **MUST** present the phase's output summary to the user
- The router **MUST** use `ask_user_question` before loading the next phase
- If the user says "stop" or "wait" at any re-entry point, the router stops and waits
- If the extract phase returns `extraction_rejected: true`, reload `gates/confirm-doc-types/SKILL.md` for field refinement, then re-enter the extract phase
- The router never loads two phases simultaneously

### Post-Pipeline: GATE E11

After the final phase completes, use `ask_user_question`:

| Option | Sub-Skill | Description |
|--------|-----------|-------------|
| Search document content | `clinical-docs-search` | Create Cortex Search Service |
| Natural language analytics | `clinical-docs-agent` | Create Cortex Agent (Analyst + Search) |
| View documents | `clinical-docs-viewer` | Build Streamlit viewer |
| Add new document type | Re-enter `gates/confirm-doc-types` | Configure additional types |
| Data governance | `$data-governance` | PHI masking and row-access policies |
| Export/share | `$declarative-sharing` | Share extracted data across accounts |

---

## Setup

1. **Load** `references/architecture.md` for pipeline architecture context
2. **Load** `config/document_type_specs.yaml` for doc type definitions (authoritative spec layer)
3. **Verify** Snowflake connection is active and target database/schema exist
4. **Run Preflight Check** for Data Model Knowledge (see below)

## Preflight Check (REQUIRED — Run at Skill Load)

Before routing to any sub-skill, verify the Clinical Docs Data Model Knowledge repository is available:

```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.{schema}.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "test", "columns": ["SEARCH_TEXT"], "limit": 1}'
);
```

| Result | Status | Behavior |
|--------|--------|----------|
| Returns results | READY | Step 0 (Data Model Knowledge pre-step) will use dynamic search results |
| Error / does not exist | MISSING | Step 0 skipped — sub-skills fall back to `config/document_type_specs.yaml` and hardcoded schema definitions. Inform user: "Clinical docs data model search service not available — using local spec definitions" |

This preflight runs ONCE at router load. The result determines whether Step 0 below executes or is skipped.

## Data Model Knowledge — Automatic Pre-Step (Conditional on Preflight)

**CRITICAL:** For intents EXTRACT, SEARCH, and AGENT, **execute Step 0 if preflight status is READY**. If preflight status is MISSING, skip Step 0 and let sub-skills use `config/document_type_specs.yaml`.

### Step 0: Query Data Model Knowledge (automatic for EXTRACT, SEARCH, AGENT)

Before generating any DDL, building pipelines, creating search services, or configuring agents:

1. **Query the clinical docs model search service** for relevant tables/columns:
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.{schema}.CLINICAL_DOCS_MODEL_SEARCH_SVC',
    '{"query": "<context from user request>", "columns": ["table_name", "column_name", "data_type", "description", "contains_phi", "relationships"]}'
);
```

2. **Optionally query the spec search service** for doc type definitions:
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    '{db}.{schema}.CLINICAL_DOCS_SPECS_SEARCH_SVC',
    '{"query": "<doc type from user request>", "columns": ["doc_type", "field_name", "extraction_question", "data_type", "contains_phi"]}'
);
```

3. **Use the search results** — not hardcoded definitions — as the source of truth for:
   - Table names and column definitions (EXTRACT)
   - Searchable columns and content structure (SEARCH)
   - Semantic View column awareness (AGENT)
   - PHI column identification (all)

4. **Pass results to the sub-skill** as grounding context.

| Intent | Step 0 Query Focus | What Gets Grounded |
|--------|-------------------|--------------------|
| EXTRACT | Config tables + extraction fields per doc type | Pipeline config, classification prompts, extraction schemas |
| SEARCH | RAW_CONTENT columns + doc classification types | Cortex Search Service column selection |
| AGENT | Pivot view columns + relationships + metrics | Semantic View dimensions, Cortex Agent tool config |
| GOVERNANCE | PHI-flagged columns across all tables | Masking policy targets |

## Workflow

```
Start
  |
  v
Run Preflight Check (CLINICAL_DOCS_MODEL_SEARCH_SVC)
  |
  v
Step 1: Verify Connection (GATE 1 + GATE 2)
  |
  v
Detect Intent (GATE 3)
  |
  v
Is intent EXTRACT, SEARCH, or AGENT?
  |                              |
  YES                            NO
  |                              |
  v                              v
  Preflight READY?               Skip Step 0
  |          |                   (VIEWER, MODEL_KNOWLEDGE)
  YES        NO                  |
  |          |                   |
  v          v                   |
  Step 0:    Skip Step 0         |
  Query      (use specs YAML     |
  CKE        + hardcoded defs)   |
  services                       |
  |          |                   |
  v          v                   v
  +---> EXTRACT --> clinical-document-extraction (grounded by CKE OR specs)
  |
  +---> SEARCH ---> clinical-docs-search (grounded by CKE OR specs)
  |
  +---> AGENT ----> clinical-docs-agent (grounded by CKE OR specs)
  |
  +---> VIEWER ---> clinical-docs-viewer
  |
  +---> MODEL_KNOWLEDGE -> data-model-knowledge (direct CKE queries)
```

## Sub-skills

| Sub-skill | File | Purpose |
|---|---|---|
| Document Extraction | `clinical-document-extraction/SKILL.md` | Orchestrator → gates → phases pipeline |
| Document Search | `clinical-docs-search/SKILL.md` | Cortex Search Service over parsed content |
| Clinical Docs Agent | `clinical-docs-agent/SKILL.md` | Cortex Agent (Analyst + Search) |
| Document Viewer | `clinical-docs-viewer/SKILL.md` | Streamlit viewer (delegates to `developing-with-streamlit`) |
| Data Model Knowledge | `data-model-knowledge/SKILL.md` | Cortex Search over schema metadata |

## Reference Files

| Path | Contents |
|------|----------|
| `references/architecture.md` | End-to-end architecture and data flow |
| `references/cortex_ai_functions.md` | Cortex AI function reference |
| `references/supported_document_types.md` | Supported types and format constraints |
| `config/document_type_specs.yaml` | Authoritative doc type definitions (CKE spec layer) |
| `references/metadata_as_cke.md` | CKE-driven metadata pattern and comparison with DICOM |

## Cross-Cutting Concerns

- **PHI Governance**: Before exposing patient data, recommend masking policies via `$data-governance`
- **Identity Linkage**: `MRN_PATIENT_MAPPING` view provides MRN-to-name mapping from extracted documents
- **CKE Integration**: Load `$cke-pubmed` for biomedical literature grounding when relevant

## Adding a New Sub-Skill

To extend this skill with a new sub-skill (e.g., `clinical-docs-export`):

1. Create the sub-skill folder and SKILL.md:
   ```
   clinical-docs-export/
     SKILL.md    # Must have parent_skill: clinical-docs
   ```

2. Add a routing entry to the Intent Routing table (Step 2) in this file:
   ```
   | Export / share / deliver | **Load** `clinical-docs-export/SKILL.md` |
   ```

3. Add a post-pipeline option to GATE E11 (Step 3, Post-Pipeline):
   ```
   | Export extracted data | `clinical-docs-export` | Export to external systems |
   ```

4. Register the sub-skill in `templates/skills_incubator.yaml`:
   ```yaml
   - name: clinical-docs-export
     triggers: "export documents, share clinical data, deliver extracts"
     description: "Export extracted clinical data to external systems"
   ```

5. Regenerate the orchestrator:
   ```bash
   python scripts/generate_orchestrators.py --profile incubator
   ```

6. If the sub-skill uses gates, create them under `clinical-docs-export/gates/`
   following the same pattern as `clinical-document-extraction/gates/`.

7. If the sub-skill uses pipeline phases, create them under
   `clinical-docs-export/phases/` following the same pattern as
   `clinical-document-extraction/phases/`.

## Mandatory Stopping Points (Gate Registry)

| Gate | Location | What to Ask |
|------|----------|-------------|
| GATE 1 | Router Step 1 | Connection & warehouse verification |
| GATE 2 | Router Step 1 | Database, schema & stage selection |
| GATE 3 | Router Step 2 | Intent routing (if ambiguous) |
| GATE E1-E3 | `gates/confirm-environment` | Environment, db/schema/stage, file location |
| GATE E4-E5 | `gates/confirm-doc-types` | Document types, extraction fields |
| GATE E6-E7 | `gates/confirm-pipeline-config` | Mode, warehouse sizing, pricing |
| GATE E8 | `phases/classify` | Classification quality (reactive) |
| GATE E9 | `phases/classify` | Unknown type detection (reactive) |
| GATE E10 | `phases/extract` | Extraction quality per type (reactive) |
| GATE E11 | Router post-pipeline | What next? |

### Enforcement Rules

- 🛑 **Every gate uses `ask_user_question`** — never embed questions in prose
- 🛑 **Never batch multiple gates** — one question at a time
- 🛑 **Never skip a gate because you have prior context** — every session starts fresh
- 🛑 **Each sub-skill has its own mandatory gates** — honour ALL of them
- 🛑 **Between pipeline phases, STOP and present results** — the user decides when to continue
