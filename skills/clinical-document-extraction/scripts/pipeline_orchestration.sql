-- =============================================================================
-- pipeline_orchestration.sql
-- Full Task DAG for Clinical Document Intelligence Pipeline
-- =============================================================================
-- Creates a stream on the stage directory table and a 5-task DAG that
-- processes documents end-to-end: preprocess → classify → extract → parse → refresh
--
-- Parameters (set before execution):
--   $V_DB        — target database
--   $V_SCHEMA    — target schema
--   $V_STAGE_FQN — fully qualified stage name (e.g., 'DB.SCHEMA.STAGE_NAME')
--                  Use this when stage is in a different schema than target
--   $V_STAGE     — stage name (unqualified fallback, assumes target schema)
--   $V_WAREHOUSE — warehouse for task execution
--   $V_MODE      — 'stream' (triggered by new files) or 'schedule'
--   $V_SCHEDULE  — schedule interval if MODE='schedule' (e.g., '1 HOUR', 'USING CRON 0 */6 * * * UTC')
-- =============================================================================

-- Resolve stage FQN: use $V_STAGE_FQN if provided, otherwise construct from $V_DB.$V_SCHEMA.$V_STAGE
-- SET V_RESOLVED_STAGE = COALESCE($V_STAGE_FQN, $V_DB || '.' || $V_SCHEMA || '.' || $V_STAGE);

-- =============================================================================
-- STEP 1: Directory Stream (detects new files arriving on stage)
-- =============================================================================
EXECUTE IMMEDIATE
    'CREATE OR REPLACE STREAM ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_DIRECTORY_STREAM' ||
    ' ON STAGE @' || COALESCE($V_STAGE_FQN, $V_DB || '.' || $V_SCHEMA || '.' || $V_STAGE);

-- =============================================================================
-- STEP 2: Root Task (triggered by stream or schedule)
-- =============================================================================
EXECUTE IMMEDIATE
    CASE
        WHEN $V_MODE = 'stream' THEN
            'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PIPELINE_ROOT
                WAREHOUSE = ' || $V_WAREHOUSE || '
                COMMENT = ''Root task: preprocess new clinical documents from stage''
                WHEN SYSTEM$STREAM_HAS_DATA(''' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_DIRECTORY_STREAM'')
            AS
                CALL ' || $V_DB || '.' || $V_SCHEMA || '.PREPROCESS_CLINICAL_DOCS()'
        WHEN $V_MODE = 'schedule' THEN
            'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PIPELINE_ROOT
                WAREHOUSE = ' || $V_WAREHOUSE || '
                SCHEDULE = ''' || $V_SCHEDULE || '''
                COMMENT = ''Root task: preprocess clinical documents on schedule''
            AS
                CALL ' || $V_DB || '.' || $V_SCHEMA || '.PREPROCESS_CLINICAL_DOCS()'
    END;

-- =============================================================================
-- STEP 3: Classify Task (runs after preprocess completes)
-- =============================================================================
EXECUTE IMMEDIATE
    'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_CLASSIFY_TASK
        WAREHOUSE = ' || $V_WAREHOUSE || '
        COMMENT = ''Classify documents by type using AI_PARSE_DOCUMENT + AI_COMPLETE''
        AFTER ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PIPELINE_ROOT
    AS
        CALL ' || $V_DB || '.' || $V_SCHEMA || '.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA()';

-- =============================================================================
-- STEP 4: Extract Task (runs after classify completes)
-- =============================================================================
EXECUTE IMMEDIATE
    'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_EXTRACT_TASK
        WAREHOUSE = ' || $V_WAREHOUSE || '
        COMMENT = ''Extract type-specific fields using AI_EXTRACT with config-driven schemas''
        AFTER ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_CLASSIFY_TASK
    AS
        CALL ' || $V_DB || '.' || $V_SCHEMA || '.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES()';

-- =============================================================================
-- STEP 5: Parse Task (runs after extract completes)
-- =============================================================================
EXECUTE IMMEDIATE
    'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PARSE_TASK
        WAREHOUSE = ' || $V_WAREHOUSE || '
        COMMENT = ''Parse documents with layout preservation using AI_PARSE_DOCUMENT''
        AFTER ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_EXTRACT_TASK
    AS
        CALL ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2()';

-- =============================================================================
-- STEP 6: Refresh Task (runs after parse completes — materializes into RAW_CONTENT)
-- =============================================================================
-- NOTE: This replaces the standalone REFRESH_RAW_CONTENT_TASK from dynamic_pipeline_setup.sql
-- when orchestration mode is 'stream' or 'schedule'. The standalone task uses its own
-- stream (DOCS_PARSE_OUTPUT_STREAM); this DAG version calls EXECUTE TASK on it.
EXECUTE IMMEDIATE
    'CREATE OR REPLACE TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_REFRESH_TASK
        WAREHOUSE = ' || $V_WAREHOUSE || '
        COMMENT = ''Refresh RAW_CONTENT table from parsed output (final DAG step)''
        AFTER ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PARSE_TASK
    AS
        EXECUTE TASK ' || $V_DB || '.' || $V_SCHEMA || '.REFRESH_RAW_CONTENT_TASK';

-- =============================================================================
-- STEP 7: Resume the DAG (activate all tasks starting from root)
-- =============================================================================
-- Tasks must be resumed in reverse order (leaf → root) per Snowflake requirements
EXECUTE IMMEDIATE 'ALTER TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_REFRESH_TASK RESUME';
EXECUTE IMMEDIATE 'ALTER TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PARSE_TASK RESUME';
EXECUTE IMMEDIATE 'ALTER TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_EXTRACT_TASK RESUME';
EXECUTE IMMEDIATE 'ALTER TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_CLASSIFY_TASK RESUME';
EXECUTE IMMEDIATE 'ALTER TASK ' || $V_DB || '.' || $V_SCHEMA || '.CLINICAL_DOCS_PIPELINE_ROOT RESUME';

-- =============================================================================
-- Done
-- =============================================================================
SELECT 'Pipeline orchestration deployed. Mode: ' || $V_MODE || 
       '. Tasks: 5 (DAG). Stream: CLINICAL_DOCS_DIRECTORY_STREAM. Root: CLINICAL_DOCS_PIPELINE_ROOT' AS STATUS;
