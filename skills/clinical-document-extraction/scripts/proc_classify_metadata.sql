-- =============================================================================
-- EXTRACT_DOCUMENT_CLASSIFICATION_METADATA
-- Classifies documents using AI_PARSE_DOCUMENT + AI_COMPLETE (two-step).
-- Replace {db} and {schema} with actual values before execution.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {db}.{schema}.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA(
    BATCH_SIZE NUMBER(38,0) DEFAULT null,
    MODEL_NAME VARCHAR DEFAULT 'llama3.1-70b'
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    rows_inserted NUMBER DEFAULT 0;
    actual_limit NUMBER;
    classification_prompt VARCHAR;
BEGIN
    actual_limit := COALESCE(BATCH_SIZE, 999999);

    SELECT 'You are a clinical document classifier. Analyze the following document text and respond with ONLY a valid JSON object (no markdown, no explanation) containing these fields:\n'
        || LISTAGG('- ' || FIELD_NAME || ': ' || EXTRACTION_QUESTION, '\n') WITHIN GROUP (ORDER BY DISPLAY_ORDER)
        || '\n\nRespond with ONLY the JSON object. Example: {"DOCUMENT_CLASSIFICATION": "DISCHARGE_SUMMARY", "COMPLEX_TABLES_FLAG": "NO", "IMAGE_FLAG": "NO"}'
    INTO :classification_prompt
    FROM {db}.{schema}.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG
    WHERE IS_ACTIVE = TRUE;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_PARSED_FOR_CLASSIFY AS
    SELECT
        dh.DOCUMENT_RELATIVE_PATH,
        dh.DOCUMENT_STAGE,
        AI_PARSE_DOCUMENT(
            TO_FILE(dh.DOCUMENT_STAGE, dh.DOCUMENT_RELATIVE_PATH),
            {'mode': 'OCR'}
        ):content::VARCHAR AS parsed_text
    FROM {db}.{schema}.DOCUMENT_HIERARCHY dh
    WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NULL
        AND NOT EXISTS (
            SELECT 1 FROM {db}.{schema}.DOCUMENT_HIERARCHY child
            WHERE child.PARENT_DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
        )
        AND NOT EXISTS (
            SELECT 1 FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcmr
            WHERE dcmr.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
        )
    LIMIT :actual_limit;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_CLASSIFIED_DOCS AS
    SELECT
        t.DOCUMENT_RELATIVE_PATH,
        t.DOCUMENT_STAGE,
        TRY_PARSE_JSON(
            AI_COMPLETE(:MODEL_NAME,
                :classification_prompt || '\n\nDocument text:\n' || LEFT(t.parsed_text, 50000)
            )
        ) AS classification_result
    FROM TEMP_PARSED_FOR_CLASSIFY t;

    INSERT INTO {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS (
        DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP, DOC_CATEGORY
    )
    SELECT
        temp.DOCUMENT_RELATIVE_PATH,
        temp.DOCUMENT_STAGE,
        config.FIELD_NAME,
        UPPER(COALESCE(
            REPLACE(temp.classification_result[config.FIELD_NAME]::VARCHAR, '_', ' '),
            'UNKNOWN'
        )) AS FIELD_VALUE,
        CURRENT_TIMESTAMP(),
        'SINGLE'
    FROM TEMP_CLASSIFIED_DOCS temp
    CROSS JOIN {db}.{schema}.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG config
    WHERE config.IS_ACTIVE = TRUE;

    rows_inserted := SQLROWCOUNT;
    DROP TABLE IF EXISTS TEMP_PARSED_FOR_CLASSIFY;
    DROP TABLE IF EXISTS TEMP_CLASSIFIED_DOCS;

    LET type_summary VARCHAR;
    SELECT LISTAGG(DISTINCT FIELD_VALUE, ', ') INTO :type_summary
    FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
    WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION';

    RETURN 'Successfully classified and inserted ' || rows_inserted || ' field value(s) using AI_PARSE_DOCUMENT + AI_COMPLETE. Types found: ' || :type_summary;
END;
$$;
