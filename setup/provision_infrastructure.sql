-- ============================================================================
-- Clinical Document Intelligence Plugin - Infrastructure Provisioning
-- Idempotent: safe to run multiple times
-- Usage: Replace {db} and {schema} with your target values, or run via plugin setup
-- ============================================================================

-- Database & Schema
CREATE DATABASE IF NOT EXISTS HCLS_CLINICAL_DOCS;
CREATE SCHEMA IF NOT EXISTS HCLS_CLINICAL_DOCS.CLINICAL_DOCS;

USE DATABASE HCLS_CLINICAL_DOCS;
USE SCHEMA CLINICAL_DOCS;

-- Internal stage for source documents (PDFs, DOCX, images)
CREATE STAGE IF NOT EXISTS CLINICAL_DOCS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- ============================================================================
-- Core Tables
-- ============================================================================

CREATE TABLE IF NOT EXISTS RAW_DOCUMENTS (
    DOC_ID VARCHAR(64) DEFAULT UUID_STRING(),
    FILE_PATH VARCHAR(500) NOT NULL,
    FILE_NAME VARCHAR(255) NOT NULL,
    FILE_TYPE VARCHAR(20),
    FILE_SIZE_BYTES NUMBER,
    UPLOAD_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    STAGE_URL VARCHAR(1000),
    METADATA VARIANT,
    PRIMARY KEY (DOC_ID)
);

CREATE TABLE IF NOT EXISTS CLASSIFIED_DOCUMENTS (
    DOC_ID VARCHAR(64) NOT NULL,
    DOCUMENT_TYPE VARCHAR(100),
    CONFIDENCE_SCORE FLOAT,
    CLASSIFICATION_MODEL VARCHAR(100),
    CLASSIFICATION_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    RAW_CLASSIFICATION VARIANT,
    PRIMARY KEY (DOC_ID),
    FOREIGN KEY (DOC_ID) REFERENCES RAW_DOCUMENTS(DOC_ID)
);

CREATE TABLE IF NOT EXISTS EXTRACTED_FIELDS (
    EXTRACTION_ID VARCHAR(64) DEFAULT UUID_STRING(),
    DOC_ID VARCHAR(64) NOT NULL,
    DOCUMENT_TYPE VARCHAR(100),
    FIELD_NAME VARCHAR(255),
    FIELD_VALUE VARCHAR(10000),
    FIELD_TYPE VARCHAR(50),
    CONFIDENCE_SCORE FLOAT,
    PAGE_NUMBER NUMBER,
    EXTRACTION_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (EXTRACTION_ID),
    FOREIGN KEY (DOC_ID) REFERENCES RAW_DOCUMENTS(DOC_ID)
);

CREATE TABLE IF NOT EXISTS PARSED_SECTIONS (
    SECTION_ID VARCHAR(64) DEFAULT UUID_STRING(),
    DOC_ID VARCHAR(64) NOT NULL,
    SECTION_NAME VARCHAR(255),
    SECTION_TEXT TEXT,
    SECTION_ORDER NUMBER,
    CONTAINS_PHI BOOLEAN DEFAULT FALSE,
    PARSE_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (SECTION_ID),
    FOREIGN KEY (DOC_ID) REFERENCES RAW_DOCUMENTS(DOC_ID)
);

-- ============================================================================
-- Governance Objects
-- ============================================================================

CREATE TAG IF NOT EXISTS PHI_LEVEL
    ALLOWED_VALUES 'HIGH', 'MEDIUM', 'LOW', 'NONE'
    COMMENT = 'PHI sensitivity level for clinical document columns';

CREATE TAG IF NOT EXISTS DOCUMENT_TYPE
    COMMENT = 'Clinical document type classification';

-- Apply PHI tags to sensitive columns
ALTER TABLE EXTRACTED_FIELDS MODIFY COLUMN FIELD_VALUE SET TAG PHI_LEVEL = 'HIGH';
ALTER TABLE PARSED_SECTIONS MODIFY COLUMN SECTION_TEXT SET TAG PHI_LEVEL = 'HIGH';

-- Masking policy for PHI columns
CREATE MASKING POLICY IF NOT EXISTS PHI_TEXT_MASK AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN IS_ROLE_IN_SESSION('CLINICAL_DOCS_PHI_ACCESS') THEN val
        WHEN IS_ROLE_IN_SESSION('CLINICAL_DOCS_ADMIN') THEN val
        ELSE '*** PHI MASKED ***'
    END;

-- Row-access policy (optional - scopes access by document type)
CREATE ROW ACCESS POLICY IF NOT EXISTS DOCUMENT_ACCESS_POLICY AS (doc_type VARCHAR) RETURNS BOOLEAN ->
    IS_ROLE_IN_SESSION('CLINICAL_DOCS_ADMIN')
    OR IS_ROLE_IN_SESSION('CLINICAL_DOCS_PHI_ACCESS')
    OR (IS_ROLE_IN_SESSION('CLINICAL_DOCS_VIEWER') AND doc_type IS NOT NULL);

-- ============================================================================
-- Audit Trail
-- ============================================================================

CREATE TABLE IF NOT EXISTS AUDIT_LOG (
    AUDIT_ID VARCHAR(64) DEFAULT UUID_STRING(),
    EVENT_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    USER_NAME VARCHAR(255) DEFAULT CURRENT_USER(),
    ROLE_NAME VARCHAR(255) DEFAULT CURRENT_ROLE(),
    ACTION_TYPE VARCHAR(50),
    TARGET_TABLE VARCHAR(255),
    SQL_HASH VARCHAR(64),
    ROW_COUNT NUMBER,
    METADATA VARIANT,
    PRIMARY KEY (AUDIT_ID)
);

-- ============================================================================
-- Cortex Search Service (created after data is loaded)
-- Note: This is a placeholder DDL. Actual creation requires data in PARSED_SECTIONS.
-- The extraction pipeline will create this after first successful parse.
-- ============================================================================

-- CREATE CORTEX SEARCH SERVICE IF NOT EXISTS CLINICAL_DOCS_SEARCH_SVC
--     ON PARSED_SECTIONS
--     WAREHOUSE = <warehouse>
--     TARGET_LAG = '1 hour'
--     AS (
--         SELECT
--             SECTION_ID,
--             DOC_ID,
--             SECTION_NAME,
--             SECTION_TEXT AS SEARCH_TEXT
--         FROM PARSED_SECTIONS
--     );

-- ============================================================================
-- Roles (recommendations - admin should create based on org structure)
-- ============================================================================

-- CREATE ROLE IF NOT EXISTS CLINICAL_DOCS_ADMIN;
-- CREATE ROLE IF NOT EXISTS CLINICAL_DOCS_PHI_ACCESS;
-- CREATE ROLE IF NOT EXISTS CLINICAL_DOCS_VIEWER;
-- GRANT ROLE CLINICAL_DOCS_PHI_ACCESS TO ROLE CLINICAL_DOCS_ADMIN;
-- GRANT ROLE CLINICAL_DOCS_VIEWER TO ROLE CLINICAL_DOCS_ADMIN;

-- ============================================================================
-- Done
-- ============================================================================
SELECT 'Infrastructure provisioning complete. Tables: 5, Tags: 2, Policies: 2, Stage: 1' AS STATUS;
