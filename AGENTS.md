# Clinical Document Intelligence Plugin — Agent Rules

> These rules are loaded into the agent's context at session start and define **required behavior** and **prohibited patterns** for all work within this plugin.

## Plugin Identity

This plugin composes skills from `skills/` into a deployable, enforceable clinical document processing solution. The skills provide domain logic; this AGENTS.md provides enforcement rules.

## Required Architecture

### Pipeline Order (MUST follow this sequence)

1. **PREPROCESS_CLINICAL_DOCS** — stage scan, metadata extraction, raw document registration
2. **EXTRACT_DOCUMENT_CLASSIFICATION_METADATA** — two-step: AI_PARSE_DOCUMENT + AI_COMPLETE via proc
3. **EXTRACT_DOC_CLASSIFICATION** — aggregated classification with confidence scoring
4. **EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES** — AI_EXTRACT with config-driven responseFormat
5. **PARSE_WITH_IMAGES_V2** — full document parsing with layout preservation

### Infrastructure Setup (MUST use prescribed scripts)

- **Schema creation**: Execute `dynamic_pipeline_setup.sql` from the composed skill's scripts folder
- **Config seeding**: Load from `config/document_type_specs.yaml` (this plugin's config)
- **Stored procedures**: Create ALL procs from skill's `scripts/proc_*.sql` files BEFORE pipeline execution
- **UDFs**: `BUILD_DOCUMENT_CLASSIFICATION_EXTRACTION_JSON()` and `BUILD_DOC_TYPE_EXTRACTION_JSON(doc_type)` — created by setup script

### Config-Driven Architecture

- **Config table**: `CLINICAL_DOCS_EXTRACTION_CONFIG` is the single source of truth for document type specifications
- **Spec source**: `config/document_type_specs.yaml` seeds the config table
- **Adding a new document type**: Add YAML entry + re-run config seeding. Do NOT modify stored procedures.

## Prohibited Patterns

| Pattern | Why Prohibited | Use Instead |
|---------|---------------|-------------|
| `SNOWFLAKE.CORTEX.COMPLETE` for classification | Bypasses two-step architecture | `CALL EXTRACT_DOCUMENT_CLASSIFICATION_METADATA()` |
| `SNOWFLAKE.CORTEX.COMPLETE` for field extraction | Bypasses config-driven extraction | `CALL EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES()` |
| Ad-hoc `CREATE TABLE` for pipeline tables | Schema drift, non-repeatable | Execute `dynamic_pipeline_setup.sql` |
| Hardcoded field lists in prompts | Not config-driven, breaks extensibility | Use `BUILD_DOC_TYPE_EXTRACTION_JSON()` UDF |
| `LATERAL FLATTEN` + `COMPLETE` for extraction | Ad-hoc pattern, not testable | Use `AI_EXTRACT` via stored procedure |
| `snow` CLI commands (`snow sql`, `snow stage`) | Bypasses tool instrumentation | Use `snowflake_sql_execute` tool |
| Skipping quality gates | No human-in-the-loop validation | MUST test ONE doc before batch |

## Cortex AI Usage Rules

### Classification (Two-Step)
```
Step 1: AI_PARSE_DOCUMENT(file_url, mode => 'OCR')  → raw text
Step 2: AI_COMPLETE(model, prompt_from_config)       → classification JSON
```
Both steps are encapsulated in `EXTRACT_DOCUMENT_CLASSIFICATION_METADATA`. Call the proc.

### Extraction (Config-Driven)
```
AI_EXTRACT(parsed_text, BUILD_DOC_TYPE_EXTRACTION_JSON(doc_type))
```
The responseFormat is built dynamically from the config table. Never hardcode field names.

### Parsing (Layout-Preserving)
```
AI_PARSE_DOCUMENT(file_url, mode => 'LAYOUT')
```
Used for full-text chunking and image extraction in `PARSE_WITH_IMAGES_V2`.

## Quality Gates (MUST NOT Skip)

| Gate | When | Action |
|------|------|--------|
| E8 | After classify proc runs on batch | Test ONE doc, present result, get approval |
| E9 | After classification | Handle unknown types (ask user to add config or skip) |
| E10 | After extract proc runs on batch | Test ONE doc per type, present fields, get approval |
| E11 | Pipeline complete | Present next-step options (search, agent, viewer, governance) |

## PHI Governance

- All pipeline tables containing patient data MUST have masking policies applied BEFORE any SELECT that returns data to the user
- The `phi-output-guard.sh` hook blocks PHI patterns in tool outputs (SSN, MRN, DOB, patient names)
- The `audit-trail.sh` hook logs all DML on PHI tables to `/tmp/clinical-docs-audit/audit.jsonl`
- Use `IS_ROLE_IN_SESSION()` (not `CURRENT_ROLE()`) in all masking/row-access policies

## File References

All domain logic lives in the composed skills (relative to plugin root):
- Router: `skills/SKILL.md`
- Scripts: `skills/clinical-document-extraction/scripts/`
- Phases: `skills/clinical-document-extraction/phases/`
- Gates: `skills/clinical-document-extraction/gates/`

Plugin-owned assets (relative to this file):
- Config: `config/document_type_specs.yaml`
- Hooks: `hooks/enforce-contract.sh`, `hooks/phi-output-guard.sh`, `hooks/audit-trail.sh`
- Setup: `setup/provision_infrastructure.sql`, `setup/preflight.py`, `setup/teardown.sql`
- Tests: `tests/test_extraction_pipeline.py`
