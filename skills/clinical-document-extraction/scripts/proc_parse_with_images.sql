-- =============================================================================
-- CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2
-- Parses documents with OCR/LAYOUT mode and optional image extraction.
-- Replace {db} and {schema} with actual values before execution.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {db}.{schema}.CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2(
    DOCUMENT_FILTER VARCHAR DEFAULT null,
    FORCE_REPARSE BOOLEAN DEFAULT FALSE
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    rows_inserted NUMBER DEFAULT 0;
    docs_to_process NUMBER DEFAULT 0;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE TEMP_DOCS_TO_PARSE AS
    WITH classified_docs AS (
        SELECT dcm.DOCUMENT_RELATIVE_PATH,
               MAX(CASE WHEN dcm.FIELD_NAME ILIKE 'complex_tables_flag' THEN dcm.FIELD_VALUE END) AS complex_tables_flag,
               MAX(CASE WHEN dcm.FIELD_NAME ILIKE 'image_flag' THEN dcm.FIELD_VALUE END) AS image_flag
        FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
        GROUP BY dcm.DOCUMENT_RELATIVE_PATH
        UNION ALL
        SELECT dh.DOCUMENT_RELATIVE_PATH, 'NO' AS complex_tables_flag, 'NO' AS image_flag
        FROM {db}.{schema}.DOCUMENT_HIERARCHY dh
        WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM {db}.{schema}.DOC_CLASSIFICATION_METADATA_ROWS dcm
                          WHERE dcm.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH)
    ),
    already_parsed AS (SELECT DISTINCT DOCUMENT_RELATIVE_PATH FROM {db}.{schema}.DOCS_PARSE_OUTPUT),
    parent_documents AS (SELECT DISTINCT PARENT_DOCUMENT_RELATIVE_PATH FROM {db}.{schema}.DOCUMENT_HIERARCHY WHERE PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL)
    SELECT dh.DOCUMENT_RELATIVE_PATH, dh.DOCUMENT_STAGE, dh.PARENT_DOCUMENT_RELATIVE_PATH, dh.PARENT_DOCUMENT_STAGE, dh.DOC_PAGES,
           COALESCE(cd.complex_tables_flag, 'NO') AS complex_tables_flag, COALESCE(cd.image_flag, 'NO') AS image_flag,
           CASE WHEN COALESCE(cd.complex_tables_flag, 'NO') = 'YES' THEN 'LAYOUT' WHEN COALESCE(cd.image_flag, 'NO') = 'YES' THEN 'LAYOUT' ELSE 'OCR' END AS parse_mode,
           CASE WHEN COALESCE(cd.image_flag, 'NO') = 'YES' THEN TRUE ELSE FALSE END AS extract_images,
           CASE WHEN dh.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL THEN COALESCE(REGEXP_SUBSTR(dh.DOCUMENT_RELATIVE_PATH, '_pages_([0-9]+)_to_', 1, 1, 'e', 1)::NUMBER, 1) ELSE 1 END AS start_page_offset
    FROM {db}.{schema}.DOCUMENT_HIERARCHY dh
    LEFT JOIN classified_docs cd ON dh.DOCUMENT_RELATIVE_PATH = cd.DOCUMENT_RELATIVE_PATH
    LEFT JOIN already_parsed ap ON dh.DOCUMENT_RELATIVE_PATH = ap.DOCUMENT_RELATIVE_PATH
    LEFT JOIN parent_documents pd ON dh.DOCUMENT_RELATIVE_PATH = pd.PARENT_DOCUMENT_RELATIVE_PATH
    WHERE (:DOCUMENT_FILTER IS NULL OR dh.DOCUMENT_RELATIVE_PATH = :DOCUMENT_FILTER)
        AND (:FORCE_REPARSE = TRUE OR ap.DOCUMENT_RELATIVE_PATH IS NULL)
        AND pd.PARENT_DOCUMENT_RELATIVE_PATH IS NULL;

    SELECT COUNT(*) INTO :docs_to_process FROM TEMP_DOCS_TO_PARSE;

    IF (docs_to_process = 0) THEN
        DROP TABLE IF EXISTS TEMP_DOCS_TO_PARSE;
        RETURN 'No new documents to parse - all documents already processed';
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_PARSED_DOCS AS
    SELECT docs.DOCUMENT_RELATIVE_PATH, docs.DOCUMENT_STAGE, docs.PARENT_DOCUMENT_RELATIVE_PATH, docs.DOC_PAGES,
           docs.parse_mode, docs.extract_images, docs.start_page_offset,
           CASE WHEN docs.parse_mode = 'LAYOUT' AND docs.extract_images = TRUE THEN
                AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {'mode': 'LAYOUT', 'page_split': true, 'extract_images': true})
           WHEN docs.parse_mode = 'LAYOUT' THEN
                AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {'mode': 'LAYOUT', 'page_split': true})
           ELSE
                AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {'mode': 'OCR', 'page_split': true})
           END AS parse_result
    FROM TEMP_DOCS_TO_PARSE docs;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_PAGES_EXTRACTED AS
    SELECT pd.DOCUMENT_RELATIVE_PATH, pd.DOCUMENT_STAGE, pd.PARENT_DOCUMENT_RELATIVE_PATH, pd.DOC_PAGES,
           pd.parse_mode, pd.extract_images, pd.start_page_offset + page.index AS PAGE_NUMBER_IN_PARENT,
           page.value:content::VARCHAR AS page_content, page.value:images AS page_images
    FROM TEMP_PARSED_DOCS pd, LATERAL FLATTEN(input => pd.parse_result:pages) page;

    CREATE OR REPLACE TEMPORARY TABLE TEMP_PARSED_PAGES AS
    WITH images_with_descriptions AS (
        SELECT pe.DOCUMENT_RELATIVE_PATH, pe.DOCUMENT_STAGE, pe.PARENT_DOCUMENT_RELATIVE_PATH, pe.DOC_PAGES,
               pe.parse_mode, pe.extract_images, pe.PAGE_NUMBER_IN_PARENT, pe.page_content,
               img.index AS image_index, img.value:id::VARCHAR AS image_id,
               AI_EXTRACT(file_data => BASE64_DECODE_BINARY(REGEXP_REPLACE(img.value:image_base64::STRING, '^data:image/[^;]+;base64,', '')),
                          responseFormat => {'Image_Description': 'Provide a detailed description of this medical image, including any visible anatomical structures, pathological findings, imaging modality characteristics, and clinically relevant observations.'}
               ):response['Image_Description']::VARCHAR AS image_description
        FROM TEMP_PAGES_EXTRACTED pe, LATERAL FLATTEN(input => pe.page_images) img
        WHERE pe.extract_images = TRUE AND pe.page_images IS NOT NULL AND ARRAY_SIZE(pe.page_images) > 0
    ),
    pages_with_image_array AS (
        SELECT DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, DOC_PAGES,
               parse_mode, extract_images, PAGE_NUMBER_IN_PARENT, page_content,
               ARRAY_AGG(OBJECT_CONSTRUCT('image_id', image_id, 'description', image_description)) WITHIN GROUP (ORDER BY image_index) AS image_data_array
        FROM images_with_descriptions
        GROUP BY DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, DOC_PAGES, parse_mode, extract_images, PAGE_NUMBER_IN_PARENT, page_content
    )
    SELECT pe.DOCUMENT_RELATIVE_PATH, pe.DOCUMENT_STAGE, pe.PARENT_DOCUMENT_RELATIVE_PATH, pe.DOC_PAGES,
           pe.parse_mode, pe.extract_images, pe.PAGE_NUMBER_IN_PARENT,
           CASE WHEN pia.image_data_array IS NOT NULL THEN {db}.{schema}.INJECT_IMAGE_DESCRIPTIONS(pe.page_content, pia.image_data_array) ELSE pe.page_content END AS final_page_content
    FROM TEMP_PAGES_EXTRACTED pe
    LEFT JOIN pages_with_image_array pia ON pe.DOCUMENT_RELATIVE_PATH = pia.DOCUMENT_RELATIVE_PATH AND pe.PAGE_NUMBER_IN_PARENT = pia.PAGE_NUMBER_IN_PARENT;

    INSERT INTO {db}.{schema}.DOCS_PARSE_OUTPUT (
        DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, PAGE_NUMBER_IN_PARENT,
        PAGE_CONTENT, DOC_TOTAL_PAGES, PARSE_MODE, EXTRACT_IMAGES, PARSE_TIMESTAMP
    )
    SELECT DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, PAGE_NUMBER_IN_PARENT,
           final_page_content, DOC_PAGES, parse_mode, extract_images, CURRENT_TIMESTAMP()
    FROM TEMP_PARSED_PAGES WHERE final_page_content IS NOT NULL;

    rows_inserted := SQLROWCOUNT;

    DROP TABLE IF EXISTS TEMP_DOCS_TO_PARSE;
    DROP TABLE IF EXISTS TEMP_PARSED_DOCS;
    DROP TABLE IF EXISTS TEMP_PAGES_EXTRACTED;
    DROP TABLE IF EXISTS TEMP_PARSED_PAGES;

    RETURN 'Successfully parsed and inserted ' || rows_inserted || ' page(s) from ' || docs_to_process || ' document(s)';
END;
$$;
