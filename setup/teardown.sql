-- ============================================================================
-- Clinical Document Intelligence Plugin - Teardown
-- WARNING: This will DROP all plugin objects. Data will be lost.
-- Usage: Run only when you want to completely remove the plugin infrastructure.
-- ============================================================================

USE DATABASE HCLS_CLINICAL_DOCS;
USE SCHEMA CLINICAL_DOCS;

-- Drop Cortex Search Service (if exists)
DROP CORTEX SEARCH SERVICE IF EXISTS CLINICAL_DOCS_SEARCH_SVC;

-- Drop policies
DROP MASKING POLICY IF EXISTS PHI_TEXT_MASK;
DROP ROW ACCESS POLICY IF EXISTS DOCUMENT_ACCESS_POLICY;

-- Drop tags
DROP TAG IF EXISTS PHI_LEVEL;
DROP TAG IF EXISTS DOCUMENT_TYPE;

-- Drop tables (reverse dependency order)
DROP TABLE IF EXISTS AUDIT_LOG;
DROP TABLE IF EXISTS PARSED_SECTIONS;
DROP TABLE IF EXISTS EXTRACTED_FIELDS;
DROP TABLE IF EXISTS CLASSIFIED_DOCUMENTS;
DROP TABLE IF EXISTS RAW_DOCUMENTS;

-- Drop stage
DROP STAGE IF EXISTS CLINICAL_DOCS_STAGE;

-- Drop schema and database
DROP SCHEMA IF EXISTS HCLS_CLINICAL_DOCS.CLINICAL_DOCS;
DROP DATABASE IF EXISTS HCLS_CLINICAL_DOCS;

SELECT 'Teardown complete. All Clinical Document Intelligence objects removed.' AS STATUS;
