#!/bin/bash
# Clinical Document Intelligence Plugin - Audit Trail
# Hook: PostToolUse (matcher: snowflake_sql_execute)
# Logs DML operations on PHI-containing tables to the audit log.

# Tables that contain PHI
PHI_TABLES=("EXTRACTED_FIELDS" "PARSED_SECTIONS" "RAW_DOCUMENTS" "CLASSIFIED_DOCUMENTS")

# Read the tool result from stdin
INPUT=$(cat)

# Extract SQL from the tool call (simplified - looks for common DML patterns)
SQL_UPPER=$(echo "$INPUT" | tr '[:lower:]' '[:upper:]')

# Check if the SQL touches PHI tables
for table in "${PHI_TABLES[@]}"; do
    if echo "$SQL_UPPER" | grep -q "$table"; then
        # Determine action type
        ACTION="UNKNOWN"
        if echo "$SQL_UPPER" | grep -qE "^(INSERT|COPY)"; then
            ACTION="INSERT"
        elif echo "$SQL_UPPER" | grep -qE "^UPDATE"; then
            ACTION="UPDATE"
        elif echo "$SQL_UPPER" | grep -qE "^DELETE"; then
            ACTION="DELETE"
        elif echo "$SQL_UPPER" | grep -qE "^SELECT"; then
            ACTION="SELECT"
        elif echo "$SQL_UPPER" | grep -qE "^(CREATE|ALTER|DROP)"; then
            ACTION="DDL"
        fi

        # Log to file (append mode) - will be picked up by audit ingestion
        AUDIT_DIR="${CLINICAL_DOCS_AUDIT_DIR:-/tmp/clinical-docs-audit}"
        mkdir -p "$AUDIT_DIR"
        
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        SQL_HASH=$(echo "$INPUT" | shasum -a 256 | cut -d' ' -f1)
        
        echo "{\"timestamp\":\"$TIMESTAMP\",\"action\":\"$ACTION\",\"table\":\"$table\",\"sql_hash\":\"$SQL_HASH\"}" >> "$AUDIT_DIR/audit.jsonl"
        
        break
    fi
done

# Always allow the operation (audit is detective, not preventive)
exit 0
