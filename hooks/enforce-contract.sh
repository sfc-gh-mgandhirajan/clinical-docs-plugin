#!/bin/bash
# enforce-contract.sh — PreToolUse hook for Clinical Document Intelligence Plugin
# Inspects SQL before execution and blocks prohibited patterns.
# See: Plugin_Execution_Plan_Enforcement.pdf (Section 5)

TOOL_NAME="$1"
SQL_CONTENT="$2"

if [[ -z "$SQL_CONTENT" ]]; then
  exit 0
fi

SQL_UPPER=$(echo "$SQL_CONTENT" | tr '[:lower:]' '[:upper:]')

# Exception: Allow CREATE PROCEDURE and CALL statements (the correct path)
if echo "$SQL_UPPER" | grep -qE '^\s*(CREATE|CREATE OR REPLACE)\s+(PROCEDURE|FUNCTION)'; then
  exit 0
fi
if echo "$SQL_UPPER" | grep -qE '^\s*CALL\s+'; then
  exit 0
fi

# BLOCK 1: CORTEX.COMPLETE for classification
if echo "$SQL_UPPER" | grep -q 'CORTEX.COMPLETE' && echo "$SQL_UPPER" | grep -qE '(CLASSIF|DOCUMENT.TYPE|DOC.TYPE|CATEGORIZ)'; then
  echo "BLOCKED: Direct CORTEX.COMPLETE for document classification is prohibited."
  echo "Resolution: Use CALL EXTRACT_DOCUMENT_CLASSIFICATION_METADATA() stored procedure."
  echo "Reference: execution_contract.cortex_ai_patterns.classification"
  exit 1
fi

# BLOCK 2: CORTEX.COMPLETE for field extraction
if echo "$SQL_UPPER" | grep -q 'CORTEX.COMPLETE' && echo "$SQL_UPPER" | grep -qE '(EXTRACT|FIELD|FINDING|DIAGNOSIS|IMPRESSION)'; then
  echo "BLOCKED: Direct CORTEX.COMPLETE for field extraction is prohibited."
  echo "Resolution: Use CALL EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES() stored procedure with AI_EXTRACT."
  echo "Reference: execution_contract.cortex_ai_patterns.extraction"
  exit 1
fi

# BLOCK 3: Ad-hoc CREATE TABLE for known pipeline tables
PIPELINE_TABLES="RAW_DOCUMENTS|CLASSIFIED_DOCUMENTS|EXTRACTED_FIELDS|PARSED_SECTIONS|DOCUMENT_CHUNKS|CLINICAL_DOCS_EXTRACTION_CONFIG"
if echo "$SQL_UPPER" | grep -qE "CREATE\s+(OR\s+REPLACE\s+)?TABLE" && echo "$SQL_UPPER" | grep -qE "$PIPELINE_TABLES"; then
  echo "BLOCKED: Ad-hoc CREATE TABLE for pipeline tables is prohibited."
  echo "Resolution: Use the prescribed schema from dynamic_pipeline_setup.sql"
  echo "Reference: execution_contract.infrastructure_scripts[0]"
  exit 1
fi

# BLOCK 4: snow CLI commands (when hook is triggered by Bash tool)
if [[ "$TOOL_NAME" == "Bash" ]] && echo "$SQL_CONTENT" | grep -qE '^\s*snow\s+(sql|stage|object)'; then
  echo "BLOCKED: snow CLI commands are prohibited in this plugin context."
  echo "Resolution: Use the snowflake_sql_execute tool instead."
  echo "Reference: execution_contract.prohibited_patterns"
  exit 1
fi

# BLOCK 5: Hardcoded extraction via LATERAL FLATTEN + COMPLETE
if echo "$SQL_UPPER" | grep -q 'LATERAL FLATTEN' && echo "$SQL_UPPER" | grep -q 'CORTEX.COMPLETE'; then
  echo "BLOCKED: Hardcoded extraction via LATERAL FLATTEN + CORTEX.COMPLETE is prohibited."
  echo "Resolution: Use AI_EXTRACT via EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES stored procedure."
  echo "Reference: execution_contract.cortex_ai_patterns.extraction"
  exit 1
fi

# No violations found — allow execution
exit 0
