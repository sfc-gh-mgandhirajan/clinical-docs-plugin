---
name: clinical-docs-extract
description: Fast-path to run the full clinical document extraction pipeline
---

Execute the full extraction pipeline on documents in the stage:

1. Load the extraction skill: `skills/clinical-document-extraction/SKILL.md`
2. Follow the phased orchestration:
   - Gate 1: Verify connection and target database/schema
   - Gate 2: Confirm document types to extract
   - Gate 3: Confirm pipeline configuration (mode, warehouse, cost estimate)
   - Phase 1: Classify documents by type
   - Phase 2: Extract structured fields per document type
   - Phase 3: Parse sections and refresh dynamic tables

After completion, suggest next steps:
- `/clinical-docs:search` to enable semantic search
- `/clinical-docs:status` to view pipeline metrics
- "Create a Cortex Agent" to enable natural language queries
