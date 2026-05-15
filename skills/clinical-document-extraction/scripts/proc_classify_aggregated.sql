-- =============================================================================
-- CLASSIFY_AGGREGATED_DOCUMENTS
-- Classifies split (multi-chunk) documents using AI_AGG across pages.
-- Replace {db} and {schema} with actual values before execution.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {db}.{schema}.CLASSIFY_AGGREGATED_DOCUMENTS(
    PARENT_DOCUMENT_FILTER VARCHAR DEFAULT null
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    rows_inserted NUMBER DEFAULT 0;
    classification_question VARCHAR;
BEGIN
    SELECT EXTRACTION_QUESTION INTO :classification_question
    FROM {db}.{schema}.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG
    WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION' AND IS_ACTIVE = TRUE LIMIT 1;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_CLASSIFIED_PARENTS AS
    WITH parent_candidates AS (
        SELECT DISTINCT
            dpo.PARENT_DOCUMENT_RELATIVE_PATH,
            dh.DOCUMENT_STAGE as PARENT_DOCUMENT_STAGE
        FROM {db}.{schema}.DOCS_PARSE_OUTPUT dpo
        INNER JOIN {db}.{schema}.DOCUMENT_HIERARCHY dh
            ON dpo.PARENT_DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
        WHERE dpo.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL
            AND (:PARENT_DOCUMENT_FILTER IS NULL OR dpo.PARENT_DOCUMENT_RELATIVE_PATH = :PARENT_DOCUMENT_FILTER)
            AND NOT EXISTS (
                SELECT 1 FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcmr
                WHERE dcmr.DOCUMENT_RELATIVE_PATH = dpo.PARENT_DOCUMENT_RELATIVE_PATH
                  AND dcmr.FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
            )
    )
    SELECT
        pc.PARENT_DOCUMENT_RELATIVE_PATH,
        pc.PARENT_DOCUMENT_STAGE,
        AI_AGG(dpo.PAGE_CONTENT, :classification_question) AS document_classification
    FROM {db}.{schema}.DOCS_PARSE_OUTPUT dpo
    INNER JOIN parent_candidates pc ON dpo.PARENT_DOCUMENT_RELATIVE_PATH = pc.PARENT_DOCUMENT_RELATIVE_PATH
    GROUP BY pc.PARENT_DOCUMENT_RELATIVE_PATH, pc.PARENT_DOCUMENT_STAGE;

    INSERT INTO {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS (
        DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP, DOC_CATEGORY
    )
    SELECT PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, 'DOCUMENT_CLASSIFICATION',
           document_classification, CURRENT_TIMESTAMP(), 'MULTIPLE'
    FROM TEMP_CLASSIFIED_PARENTS WHERE document_classification IS NOT NULL;

    rows_inserted := SQLROWCOUNT;
    DROP TABLE IF EXISTS TEMP_CLASSIFIED_PARENTS;

    LET type_summary VARCHAR;
    SELECT LISTAGG(DISTINCT FIELD_VALUE, ', ') INTO :type_summary
    FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS
    WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION';

    RETURN 'Successfully classified ' || rows_inserted || ' parent document(s) using AI_AGG. Types found: ' || :type_summary;
END;
$$;
