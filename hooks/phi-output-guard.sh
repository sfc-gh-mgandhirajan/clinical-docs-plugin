#!/bin/bash
# Clinical Document Intelligence Plugin - PHI Output Guard
# Hook: PreToolUse (matcher: Write|Read)
# Blocks output containing PHI patterns when masking policies are not confirmed active.

# PHI patterns to detect (regex)
PHI_PATTERNS=(
    '[0-9]{3}-[0-9]{2}-[0-9]{4}'          # SSN
    'MRN[:\s]*[A-Z0-9\-]+'                 # Medical Record Number
    '[0-9]{2}/[0-9]{2}/[0-9]{4}'           # DOB (MM/DD/YYYY)
    'DOB[:\s]*'                             # DOB label
    'Patient[:\s]+[A-Z][a-z]+ [A-Z][a-z]+' # Patient name pattern
)

# Read the tool input from stdin
INPUT=$(cat)

# Check if this is a write/read operation that might expose PHI
TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"

# Only check content-producing operations
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Read" ]]; then
    for pattern in "${PHI_PATTERNS[@]}"; do
        if echo "$INPUT" | grep -qE "$pattern"; then
            # Check if we're in a governed context (env var set by preflight)
            if [[ -z "$CLINICAL_DOCS_PHI_MASKING_ACTIVE" ]]; then
                echo "BLOCK: Potential PHI detected in output. Masking policy not confirmed active."
                echo "Resolution: Run /clinical-docs:status to verify governance is configured,"
                echo "or set CLINICAL_DOCS_PHI_MASKING_ACTIVE=true after confirming policies."
                exit 1
            fi
        fi
    done
fi

# Allow the operation to proceed
exit 0
