-- =============================================================================
-- EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES
-- Extracts type-specific fields using AI_EXTRACT for single (non-split) docs.
-- Replace {db} and {schema} with actual values before execution.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {db}.{schema}.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES(
    BATCH_SIZE NUMBER(38,0) DEFAULT null,
    DOCUMENT_CLASSIFICATION_FILTER VARCHAR DEFAULT null
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    rows_inserted NUMBER DEFAULT 0;
    actual_limit NUMBER;
BEGIN
    actual_limit := COALESCE(:BATCH_SIZE, 999999);

    CREATE OR REPLACE TEMPORARY TABLE TEMP_DOCS_TO_PROCESS AS
    SELECT
        dcm.DOCUMENT_RELATIVE_PATH,
        dcm.DOCUMENT_STAGE,
        dcm.FIELD_VALUE AS DOCUMENT_CLASSIFICATION
    FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
    WHERE dcm.FIELD_NAME iLIKE 'DOCUMENT_CLASSIFICATION'
      AND (:DOCUMENT_CLASSIFICATION_FILTER IS NULL OR dcm.FIELD_VALUE ILIKE :DOCUMENT_CLASSIFICATION_FILTER)
      AND NOT EXISTS (
          SELECT 1 FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
          WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
            AND output.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE
      )
      AND EXISTS (
          SELECT 1 FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
          WHERE config.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND config.IS_ACTIVE = TRUE
      )
    LIMIT :actual_limit;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_EXTRACTED_VALUES AS
    SELECT
        inner_query.DOCUMENT_RELATIVE_PATH,
        inner_query.DOCUMENT_STAGE,
        inner_query.DOCUMENT_CLASSIFICATION,
        inner_query.ai_extract_response
    FROM (
        SELECT
            docs.DOCUMENT_RELATIVE_PATH,
            docs.DOCUMENT_STAGE,
            docs.DOCUMENT_CLASSIFICATION,
            AI_EXTRACT(
                file => TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH),
                responseFormat => {db}.{schema}.BUILD_DOC_TYPE_EXTRACTION_JSON(docs.DOCUMENT_CLASSIFICATION)
            ) AS ai_extract_response
        FROM TEMP_DOCS_TO_PROCESS docs
    ) inner_query;

    INSERT INTO {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT (
        DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOCUMENT_CLASSIFICATION, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP
    )
    SELECT
        temp.DOCUMENT_RELATIVE_PATH,
        temp.DOCUMENT_STAGE,
        temp.DOCUMENT_CLASSIFICATION,
        config.FIELD_NAME,
        GET_PATH(temp.ai_extract_response, 'response.' || config.FIELD_NAME)::VARCHAR AS FIELD_VALUE,
        CURRENT_TIMESTAMP()
    FROM TEMP_EXTRACTED_VALUES temp
    INNER JOIN {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
        ON config.DOCUMENT_CLASSIFICATION ILIKE temp.DOCUMENT_CLASSIFICATION AND config.IS_ACTIVE = TRUE;

    rows_inserted := SQLROWCOUNT;
    DROP TABLE IF EXISTS TEMP_DOCS_TO_PROCESS;
    DROP TABLE IF EXISTS TEMP_EXTRACTED_VALUES;

    LET skipped_count NUMBER DEFAULT 0;
    SELECT COUNT(DISTINCT dcm.DOCUMENT_RELATIVE_PATH) INTO :skipped_count
    FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
    WHERE dcm.FIELD_NAME ILIKE 'DOCUMENT_CLASSIFICATION'
      AND NOT EXISTS (
          SELECT 1 FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
          WHERE config.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND config.IS_ACTIVE = TRUE
      )
      AND NOT EXISTS (
          SELECT 1 FROM {db}.{schema}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
          WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
      );

    RETURN 'Successfully extracted and inserted ' || rows_inserted || ' field value(s)' ||
        CASE WHEN :skipped_count > 0
        THEN '. WARNING: ' || :skipped_count || ' document(s) skipped — no extraction config for their classification type.'
        ELSE '' END;
END;
$$;
