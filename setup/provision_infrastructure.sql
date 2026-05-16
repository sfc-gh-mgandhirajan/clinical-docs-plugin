-- =============================================================================
-- Clinical Document Intelligence Plugin — Infrastructure Provisioning
-- =============================================================================
-- This is a THIN WRAPPER that sets session variables and calls the real
-- infrastructure script: skills/clinical-document-extraction/scripts/dynamic_pipeline_setup.sql
--
-- The dynamic_pipeline_setup.sql creates ALL pipeline objects:
--   8 tables, 3 UDFs, 1 stream, 1 refresh task, and the GENERATE_DYNAMIC_OBJECTS proc
--
-- Usage:
--   SET V_DB = 'YOUR_DATABASE';
--   SET V_SCHEMA = 'YOUR_SCHEMA';
--   SET V_STAGE = 'YOUR_STAGE';
--   SET V_WAREHOUSE = 'YOUR_WAREHOUSE';
--   Then execute dynamic_pipeline_setup.sql
--
-- If deploying via /clinical-docs:deploy, DEPLOY.md handles this automatically.
-- This file exists for manual/scripted deployments outside of CoCo.
-- =============================================================================

-- Set these before running dynamic_pipeline_setup.sql:
SET V_DB = 'REPLACE_WITH_YOUR_DATABASE';
SET V_SCHEMA = 'REPLACE_WITH_YOUR_SCHEMA';
SET V_STAGE = 'REPLACE_WITH_YOUR_STAGE';
SET V_WAREHOUSE = 'REPLACE_WITH_YOUR_WAREHOUSE';

-- Create database and schema if needed:
CREATE DATABASE IF NOT EXISTS IDENTIFIER($V_DB);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($V_DB || '.' || $V_SCHEMA);

-- Now execute: skills/clinical-document-extraction/scripts/dynamic_pipeline_setup.sql
-- (The dynamic setup script reads $V_DB, $V_SCHEMA, $V_STAGE, $V_WAREHOUSE session variables)

-- After dynamic_pipeline_setup.sql completes, seed the config table from:
-- config/document_type_specs.yaml
-- Then run: CALL {db}.{schema}.GENERATE_DYNAMIC_OBJECTS();
