-- =============================================================================
-- CLINICAL DOCUMENTS - PIPELINE STORED PROCEDURES
-- =============================================================================
-- Ported from clinical_document_extraction/Code/snowflake_db_setup.sql
-- Parameterized using EXECUTE IMMEDIATE + session variables to remove all
-- hardcoded DEMO_DB.CLINICAL_DOCS. references.
--
-- Prerequisites: Run dynamic_pipeline_setup.sql first (creates tables + UDFs)
--
-- EXECUTION NOTES (for CoCo agents executing this script):
-- -------------------------------------------------------
-- 1. This script uses EXECUTE IMMEDIATE blocks with deeply nested quote
--    escaping (4+ levels). DO NOT pass these through shell quoting
--    (snow sql -q "...") — they WILL break.
--
-- 2. RECOMMENDED EXECUTION METHOD: Use snowflake_sql_execute tool to run
--    the entire file contents, or run via Snowflake worksheet. The file
--    has a single outer EXECUTE IMMEDIATE block that wraps all 6 procedures.
--
-- 3. ALTERNATIVE: If snowflake_sql_execute times out on the full file,
--    split at each numbered procedure comment (-- 1. through -- 6.) and
--    run each EXECUTE IMMEDIATE block separately. Each proc is independent.
--
-- 4. DO NOT use `snow sql -f` for this file — the nested $$ delimiters
--    and escaped quotes will be mangled by the CLI's shell interpretation.
-- =============================================================================

-- ======================== CONFIGURATION VARIABLES ============================
SET V_DB              = 'HCLS_COCO_TEST_DB';
SET V_SCHEMA          = 'CLINICAL_DOCS_ACTIVATION';
SET V_WAREHOUSE       = 'DEMO_BUILD_WH';
SET V_STAGE           = 'INTERNAL_CLINICAL_DOCS_STAGE';
-- =============================================================================

USE WAREHOUSE IDENTIFIER($V_WAREHOUSE);
USE DATABASE IDENTIFIER($V_DB);
USE SCHEMA IDENTIFIER($V_SCHEMA);

EXECUTE IMMEDIATE
$$
BEGIN
    LET v_fqn := $V_DB || '.' || $V_SCHEMA;
    LET v_stage_fqn := $V_DB || '.' || $V_SCHEMA || '.' || $V_STAGE;

    -- =========================================================================
    -- 1. EXTRACT_DOCUMENT_CLASSIFICATION_METADATA
    --    Uses AI_PARSE_DOCUMENT + AI_COMPLETE (two-step) for classification.
    --    AI_EXTRACT was unreliable — returned the same type for all documents.
    --    Step 1: Parse doc with AI_PARSE_DOCUMENT (OCR mode) to get full text.
    --    Step 2: Pass parsed text to AI_COMPLETE with classification prompt.
    --    Step 3: Parse JSON response for DOCUMENT_CLASSIFICATION and metadata flags.
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.EXTRACT_DOCUMENT_CLASSIFICATION_METADATA(BATCH_SIZE NUMBER(38,0) DEFAULT null, MODEL_NAME VARCHAR DEFAULT ''''llama3.1-70b'''')
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS OWNER
    AS ''DECLARE
        rows_inserted NUMBER DEFAULT 0;
        actual_limit NUMBER;
        classification_prompt VARCHAR;
    BEGIN
        actual_limit := COALESCE(BATCH_SIZE, 999999);

        SELECT ''''You are a clinical document classifier. Analyze the following document text and respond with ONLY a valid JSON object (no markdown, no explanation) containing these fields:\n''''
            || LISTAGG(''''- '''' || FIELD_NAME || '''': '''' || EXTRACTION_QUESTION, ''''\n'''') WITHIN GROUP (ORDER BY DISPLAY_ORDER)
            || ''''\n\nRespond with ONLY the JSON object. Example: {"DOCUMENT_CLASSIFICATION": "DISCHARGE_SUMMARY", "COMPLEX_TABLES_FLAG": "NO", "IMAGE_FLAG": "NO"}''''
        INTO :classification_prompt
        FROM ' || :v_fqn || '.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG
        WHERE IS_ACTIVE = TRUE;

        CREATE OR REPLACE TEMPORARY TABLE TEMP_PARSED_FOR_CLASSIFY AS
        SELECT
            dh.DOCUMENT_RELATIVE_PATH,
            dh.DOCUMENT_STAGE,
            AI_PARSE_DOCUMENT(
                TO_FILE(dh.DOCUMENT_STAGE, dh.DOCUMENT_RELATIVE_PATH),
                {''''mode'''': ''''OCR''''}
            ):content::VARCHAR AS parsed_text
        FROM ' || :v_fqn || '.DOCUMENT_HIERARCHY dh
        WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM ' || :v_fqn || '.DOCUMENT_HIERARCHY child
                WHERE child.PARENT_DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
            )
            AND NOT EXISTS (
                SELECT 1 FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcmr
                WHERE dcmr.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
            )
        LIMIT :actual_limit;

        CREATE OR REPLACE TEMPORARY TABLE TEMP_CLASSIFIED_DOCS AS
        SELECT
            t.DOCUMENT_RELATIVE_PATH,
            t.DOCUMENT_STAGE,
            TRY_PARSE_JSON(
                AI_COMPLETE(:MODEL_NAME,
                    :classification_prompt || ''''\n\nDocument text:\n'''' || LEFT(t.parsed_text, 50000)
                )
            ) AS classification_result
        FROM TEMP_PARSED_FOR_CLASSIFY t;

        INSERT INTO ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS (
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP, DOC_CATEGORY
        )
        SELECT
            temp.DOCUMENT_RELATIVE_PATH,
            temp.DOCUMENT_STAGE,
            config.FIELD_NAME,
            UPPER(COALESCE(
                REPLACE(temp.classification_result[config.FIELD_NAME]::VARCHAR, ''''_'''', '''' ''''),
                ''''UNKNOWN''''
            )) AS FIELD_VALUE,
            CURRENT_TIMESTAMP(),
            ''''SINGLE''''
        FROM TEMP_CLASSIFIED_DOCS temp
        CROSS JOIN ' || :v_fqn || '.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG config
        WHERE config.IS_ACTIVE = TRUE;

        rows_inserted := SQLROWCOUNT;
        DROP TABLE IF EXISTS TEMP_PARSED_FOR_CLASSIFY;
        DROP TABLE IF EXISTS TEMP_CLASSIFIED_DOCS;

        LET type_summary VARCHAR;
        SELECT LISTAGG(DISTINCT FIELD_VALUE, '''', '''') INTO :type_summary
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS
        WHERE FIELD_NAME = ''''DOCUMENT_CLASSIFICATION'''';

        RETURN ''''Successfully classified and inserted '''' || rows_inserted || '''' field value(s) using AI_PARSE_DOCUMENT + AI_COMPLETE. Types found: '''' || :type_summary;
    END''';

    -- =========================================================================
    -- 2. EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES(BATCH_SIZE NUMBER(38,0) DEFAULT null, DOCUMENT_CLASSIFICATION_FILTER VARCHAR DEFAULT null)
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS OWNER
    AS ''DECLARE
        rows_inserted NUMBER DEFAULT 0;
        actual_limit NUMBER;
    BEGIN
        actual_limit := COALESCE(:BATCH_SIZE, 999999);

        CREATE OR REPLACE TEMPORARY TABLE TEMP_DOCS_TO_PROCESS AS
        SELECT
            dcm.DOCUMENT_RELATIVE_PATH,
            dcm.DOCUMENT_STAGE,
            dcm.FIELD_VALUE AS DOCUMENT_CLASSIFICATION
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
        WHERE dcm.FIELD_NAME iLIKE ''''DOCUMENT_CLASSIFICATION''''
          AND (:DOCUMENT_CLASSIFICATION_FILTER IS NULL OR dcm.FIELD_VALUE ILIKE :DOCUMENT_CLASSIFICATION_FILTER)
          AND NOT EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
              WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
                AND output.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE
          )
          AND EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
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
                    responseFormat => ' || :v_fqn || '.BUILD_DOC_TYPE_EXTRACTION_JSON(docs.DOCUMENT_CLASSIFICATION)
                ) AS ai_extract_response
            FROM TEMP_DOCS_TO_PROCESS docs
        ) inner_query;

        INSERT INTO ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT (
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOCUMENT_CLASSIFICATION, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP
        )
        SELECT
            temp.DOCUMENT_RELATIVE_PATH,
            temp.DOCUMENT_STAGE,
            temp.DOCUMENT_CLASSIFICATION,
            config.FIELD_NAME,
            GET_PATH(temp.ai_extract_response, ''''response.'''' || config.FIELD_NAME)::VARCHAR AS FIELD_VALUE,
            CURRENT_TIMESTAMP()
        FROM TEMP_EXTRACTED_VALUES temp
        INNER JOIN ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
            ON config.DOCUMENT_CLASSIFICATION ILIKE temp.DOCUMENT_CLASSIFICATION AND config.IS_ACTIVE = TRUE;

        rows_inserted := SQLROWCOUNT;
        DROP TABLE IF EXISTS TEMP_DOCS_TO_PROCESS;
        DROP TABLE IF EXISTS TEMP_EXTRACTED_VALUES;

        LET skipped_count NUMBER DEFAULT 0;
        SELECT COUNT(DISTINCT dcm.DOCUMENT_RELATIVE_PATH) INTO :skipped_count
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
        WHERE dcm.FIELD_NAME ILIKE ''''DOCUMENT_CLASSIFICATION''''
          AND NOT EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
              WHERE config.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND config.IS_ACTIVE = TRUE
          )
          AND NOT EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
              WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
          );

        RETURN ''''Successfully extracted and inserted '''' || rows_inserted || '''' field value(s)'''' ||
            CASE WHEN :skipped_count > 0
            THEN ''''. WARNING: '''' || :skipped_count || '''' document(s) skipped — no extraction config for their classification type.''''
            ELSE '''''''' END;
    END''';

    -- =========================================================================
    -- 3. CLASSIFY_AGGREGATED_DOCUMENTS (split documents via AI_AGG)
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.CLASSIFY_AGGREGATED_DOCUMENTS(PARENT_DOCUMENT_FILTER VARCHAR DEFAULT null)
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS OWNER
    AS ''
    DECLARE
        rows_inserted NUMBER DEFAULT 0;
        classification_question VARCHAR;
    BEGIN
        SELECT EXTRACTION_QUESTION INTO :classification_question
        FROM ' || :v_fqn || '.DOCUMENT_CLASSIFICATION_EXTRACTION_FIELD_CONFIG
        WHERE FIELD_NAME = ''''DOCUMENT_CLASSIFICATION'''' AND IS_ACTIVE = TRUE LIMIT 1;

        CREATE OR REPLACE TEMPORARY TABLE TEMP_CLASSIFIED_PARENTS AS
        WITH parent_candidates AS (
            SELECT DISTINCT
                dpo.PARENT_DOCUMENT_RELATIVE_PATH,
                dh.DOCUMENT_STAGE as PARENT_DOCUMENT_STAGE
            FROM ' || :v_fqn || '.DOCS_PARSE_OUTPUT dpo
            INNER JOIN ' || :v_fqn || '.DOCUMENT_HIERARCHY dh
                ON dpo.PARENT_DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH
            WHERE dpo.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL
                AND (:PARENT_DOCUMENT_FILTER IS NULL OR dpo.PARENT_DOCUMENT_RELATIVE_PATH = :PARENT_DOCUMENT_FILTER)
                AND NOT EXISTS (
                    SELECT 1 FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcmr
                    WHERE dcmr.DOCUMENT_RELATIVE_PATH = dpo.PARENT_DOCUMENT_RELATIVE_PATH
                      AND dcmr.FIELD_NAME = ''''DOCUMENT_CLASSIFICATION''''
                )
        )
        SELECT
            pc.PARENT_DOCUMENT_RELATIVE_PATH,
            pc.PARENT_DOCUMENT_STAGE,
            AI_AGG(dpo.PAGE_CONTENT, :classification_question) AS document_classification
        FROM ' || :v_fqn || '.DOCS_PARSE_OUTPUT dpo
        INNER JOIN parent_candidates pc ON dpo.PARENT_DOCUMENT_RELATIVE_PATH = pc.PARENT_DOCUMENT_RELATIVE_PATH
        GROUP BY pc.PARENT_DOCUMENT_RELATIVE_PATH, pc.PARENT_DOCUMENT_STAGE;

        INSERT INTO ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS (
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP, DOC_CATEGORY
        )
        SELECT PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, ''''DOCUMENT_CLASSIFICATION'''',
               document_classification, CURRENT_TIMESTAMP(), ''''MULTIPLE''''
        FROM TEMP_CLASSIFIED_PARENTS WHERE document_classification IS NOT NULL;

        rows_inserted := SQLROWCOUNT;
        DROP TABLE IF EXISTS TEMP_CLASSIFIED_PARENTS;

        LET type_summary VARCHAR;
        SELECT LISTAGG(DISTINCT FIELD_VALUE, '''', '''') INTO :type_summary
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS
        WHERE FIELD_NAME = ''''DOCUMENT_CLASSIFICATION'''';

        RETURN ''''Successfully classified '''' || rows_inserted || '''' parent document(s) using AI_AGG. Types found: '''' || :type_summary;
    END;
    ''';

    -- =========================================================================
    -- 4. EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG (split documents)
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.EXTRACT_DOCUMENT_TYPE_SPECIFIC_VALUES_WITH_AI_AGG(PARENT_DOCUMENT_FILTER VARCHAR DEFAULT null)
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS OWNER
    AS ''
    DECLARE
        total_rows_inserted NUMBER DEFAULT 0;
        batch_rows_inserted NUMBER DEFAULT 0;
        current_classification VARCHAR;
        extraction_prompt VARCHAR;
        classifications_cursor CURSOR FOR SELECT DISTINCT DOCUMENT_CLASSIFICATION FROM TEMP_CLASSIFICATIONS_TO_PROCESS;
    BEGIN
        CREATE OR REPLACE TEMPORARY TABLE TEMP_ALL_PARENTS_TO_PROCESS AS
        SELECT dcm.DOCUMENT_RELATIVE_PATH AS PARENT_DOCUMENT_RELATIVE_PATH,
               dcm.DOCUMENT_STAGE AS PARENT_DOCUMENT_STAGE,
               dcm.FIELD_VALUE AS DOCUMENT_CLASSIFICATION
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
        WHERE dcm.DOC_CATEGORY = ''''MULTIPLE'''' AND dcm.FIELD_NAME = ''''DOCUMENT_CLASSIFICATION''''
          AND (:PARENT_DOCUMENT_FILTER IS NULL OR dcm.DOCUMENT_RELATIVE_PATH = :PARENT_DOCUMENT_FILTER)
          AND EXISTS (SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
                      WHERE config.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND config.IS_ACTIVE = TRUE)
          AND NOT EXISTS (SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
                          WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
                            AND output.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE);

        CREATE OR REPLACE TEMPORARY TABLE TEMP_CLASSIFICATIONS_TO_PROCESS AS
        SELECT DISTINCT DOCUMENT_CLASSIFICATION FROM TEMP_ALL_PARENTS_TO_PROCESS;

        FOR classification_record IN classifications_cursor DO
            current_classification := classification_record.DOCUMENT_CLASSIFICATION;

            SELECT ''''Extract the following fields from the document text and return ONLY a JSON object with this exact structure: {"response": {'''' ||
                   LISTAGG(''''"'''' || FIELD_NAME || ''''"'''' || '''': "value"'''', '''', '''') WITHIN GROUP (ORDER BY FIELD_NAME) ||
                   ''''}}. Fields to extract: '''' || LISTAGG(FIELD_NAME, '''', '''') WITHIN GROUP (ORDER BY FIELD_NAME) ||
                   ''''. If a field is not found, set its value to null.''''
            INTO :extraction_prompt
            FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG
            WHERE DOCUMENT_CLASSIFICATION ILIKE :current_classification AND IS_ACTIVE = TRUE
            GROUP BY DOCUMENT_CLASSIFICATION;

            CREATE OR REPLACE TEMPORARY TABLE TEMP_PARENTS_CURRENT_CLASS AS
            SELECT PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, DOCUMENT_CLASSIFICATION
            FROM TEMP_ALL_PARENTS_TO_PROCESS WHERE DOCUMENT_CLASSIFICATION ILIKE :current_classification;

            CREATE OR REPLACE TEMPORARY TABLE TEMP_EXTRACTED_VALUES_CURRENT AS
            SELECT ptp.PARENT_DOCUMENT_RELATIVE_PATH, ptp.PARENT_DOCUMENT_STAGE, ptp.DOCUMENT_CLASSIFICATION,
                   PARSE_JSON(AI_AGG(dpo.PAGE_CONTENT, :extraction_prompt)) AS ai_agg_response
            FROM ' || :v_fqn || '.DOCS_PARSE_OUTPUT dpo
            INNER JOIN TEMP_PARENTS_CURRENT_CLASS ptp ON dpo.PARENT_DOCUMENT_RELATIVE_PATH = ptp.PARENT_DOCUMENT_RELATIVE_PATH
            GROUP BY ptp.PARENT_DOCUMENT_RELATIVE_PATH, ptp.PARENT_DOCUMENT_STAGE, ptp.DOCUMENT_CLASSIFICATION;

            INSERT INTO ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT (
                DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOCUMENT_CLASSIFICATION, FIELD_NAME, FIELD_VALUE, EXTRACTION_TIMESTAMP
            )
            SELECT temp.PARENT_DOCUMENT_RELATIVE_PATH, temp.PARENT_DOCUMENT_STAGE, temp.DOCUMENT_CLASSIFICATION,
                   config.FIELD_NAME, GET_PATH(temp.ai_agg_response, ''''response.'''' || config.FIELD_NAME)::VARCHAR, CURRENT_TIMESTAMP()
            FROM TEMP_EXTRACTED_VALUES_CURRENT temp
            INNER JOIN ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
                ON config.DOCUMENT_CLASSIFICATION ILIKE temp.DOCUMENT_CLASSIFICATION AND config.IS_ACTIVE = TRUE;

            batch_rows_inserted := SQLROWCOUNT;
            total_rows_inserted := total_rows_inserted + batch_rows_inserted;
            DROP TABLE IF EXISTS TEMP_PARENTS_CURRENT_CLASS;
            DROP TABLE IF EXISTS TEMP_EXTRACTED_VALUES_CURRENT;
        END FOR;

        DROP TABLE IF EXISTS TEMP_ALL_PARENTS_TO_PROCESS;
        DROP TABLE IF EXISTS TEMP_CLASSIFICATIONS_TO_PROCESS;

        LET skipped_count NUMBER DEFAULT 0;
        SELECT COUNT(DISTINCT dcm.DOCUMENT_RELATIVE_PATH) INTO :skipped_count
        FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
        WHERE dcm.DOC_CATEGORY = ''''MULTIPLE'''' AND dcm.FIELD_NAME = ''''DOCUMENT_CLASSIFICATION''''
          AND NOT EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG config
              WHERE config.DOCUMENT_CLASSIFICATION ILIKE dcm.FIELD_VALUE AND config.IS_ACTIVE = TRUE
          )
          AND NOT EXISTS (
              SELECT 1 FROM ' || :v_fqn || '.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT output
              WHERE output.DOCUMENT_RELATIVE_PATH = dcm.DOCUMENT_RELATIVE_PATH
          );

        RETURN ''''Successfully extracted and inserted '''' || total_rows_inserted || '''' field value(s) using AI_AGG'''' ||
            CASE WHEN :skipped_count > 0
            THEN ''''. WARNING: '''' || :skipped_count || '''' document(s) skipped — no extraction config for their classification type.''''
            ELSE '''''''' END;
    END;
    ''';

    -- =========================================================================
    -- 5. PREPROCESS_CLINICAL_DOCS (Python stored procedure)
    --    FQN prefix is baked into the Python string literals via EXECUTE IMMEDIATE
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.PREPROCESS_CLINICAL_DOCS(
        FILE_NAME VARCHAR DEFAULT null,
        STAGE_NAME VARCHAR DEFAULT ''@' || :v_fqn || '.' || $V_STAGE || ''',
        OUTPUT_STAGE VARCHAR DEFAULT ''@' || :v_fqn || '.' || $V_STAGE || '/processed'',
        MAX_PAGES_PER_CHUNK NUMBER(38,0) DEFAULT 125,
        MAX_SIZE_MB_PER_CHUNK FLOAT DEFAULT 100
    )
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = ''3.11''
    PACKAGES = (''snowflake-snowpark-python'',''PyPDF2'')
    HANDLER = ''preprocess_handler''
    EXECUTE AS CALLER
    AS $$
from PyPDF2 import PdfReader, PdfWriter
from snowflake.snowpark.files import SnowflakeFile
from io import BytesIO
import tempfile
import os
import json

FQN_PREFIX = "' || :v_fqn || '"
SUPPORTED_NON_PDF_EXTENSIONS = (".docx", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".txt")

def check_document_exists(session, relative_path, stage):
    check_sql = f"""
    SELECT COUNT(*) as COUNT FROM {FQN_PREFIX}.DOCUMENT_HIERARCHY
    WHERE DOCUMENT_RELATIVE_PATH = \\''{relative_path}\\'' AND DOCUMENT_STAGE = \\''{stage}\\'
    """
    result = session.sql(check_sql).collect()
    return result[0]["COUNT"] > 0

def process_single_pdf(session, file_name, stage_name, output_stage, max_pages, max_size_mb, base_qualified_stage, subdirectory):
    result = {"status": "success", "original_file": file_name, "original_pages": 0, "original_size_mb": 0,
              "needs_splitting": False, "chunks_created": 0, "message": ""}
    try:
        if subdirectory:
            relative_path = f"{subdirectory}/{file_name}"
        else:
            relative_path = file_name

        if check_document_exists(session, relative_path, base_qualified_stage):
            result["status"] = "skipped"
            result["message"] = f"Document already processed: {relative_path}"
            result["duplicate_detected"] = True
            return result

        clean_input = stage_name.lstrip("@")
        if "." not in clean_input:
            full_qualified_stage = f"@{FQN_PREFIX}.{clean_input}"
        else:
            full_qualified_stage = f"@{clean_input}"

        file_url_sql = f"SELECT build_scoped_file_url(\\'{full_qualified_stage}\\', \\'{file_name}\\')"
        result_row = session.sql(file_url_sql).collect()
        scoped_url = result_row[0][0]

        with SnowflakeFile.open(scoped_url, "rb") as f:
            pdf_bytes = f.readall()

        pdf_reader = PdfReader(BytesIO(pdf_bytes))
        total_pages = len(pdf_reader.pages)
        total_size_mb = len(pdf_bytes) / (1024 * 1024)

        result["original_pages"] = total_pages
        result["original_size_mb"] = round(total_size_mb, 2)

        insert_original_sql = f"""
        INSERT INTO {FQN_PREFIX}.DOCUMENT_HIERARCHY (
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOC_PAGES, DOC_SIZE_MB,
            PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, CREATED_TIMESTAMP, SPLIT_REASON, PARENT_DOCUMENT_SPLIT_SEQUENCE
        ) VALUES (\\'{relative_path}\\', \\'{base_qualified_stage}\\', {total_pages}, {round(total_size_mb, 2)}, NULL, NULL, CURRENT_TIMESTAMP(), NULL, NULL)
        """
        session.sql(insert_original_sql).collect()

        if total_pages <= max_pages and total_size_mb <= max_size_mb:
            result["needs_splitting"] = False
            result["message"] = f"Document within limits ({total_pages} pages, {total_size_mb:.1f}MB) - no splitting needed"
        else:
            result["needs_splitting"] = True
            result["message"] = f"Document exceeds limits ({total_pages} pages, {total_size_mb:.1f}MB) - splitting required"

            if output_stage:
                clean_output_input = output_stage.lstrip("@")
                output_parts = clean_output_input.split("/")
                output_base_stage = output_parts[0]
                output_subdirectory = "/".join(output_parts[1:]) if len(output_parts) > 1 else ""
                output_qualified_stage = f"@{output_base_stage}"
            else:
                output_base_stage = base_qualified_stage.lstrip("@")
                output_subdirectory = subdirectory
                output_qualified_stage = base_qualified_stage

            base_name = file_name.rsplit(".", 1)[0]
            chunks_created = []
            num_chunks = (total_pages + max_pages - 1) // max_pages
            temp_dir = tempfile.mkdtemp()

            try:
                for chunk_idx in range(num_chunks):
                    start_page = chunk_idx * max_pages
                    end_page = min((chunk_idx + 1) * max_pages, total_pages)

                    writer = PdfWriter()
                    for page_num in range(start_page, end_page):
                        writer.add_page(pdf_reader.pages[page_num])

                    chunk_filename = f"{base_name}_pages_{start_page + 1}_to_{end_page}.pdf"
                    tmp_path = os.path.join(temp_dir, chunk_filename)

                    with open(tmp_path, "wb") as out_pdf:
                        writer.write(out_pdf)

                    chunk_size_mb = os.path.getsize(tmp_path) / (1024 * 1024)
                    chunk_pages = end_page - start_page

                    if output_subdirectory:
                        upload_path = f"{output_qualified_stage}/{output_subdirectory}"
                        chunk_relative_path = f"{output_subdirectory}/{chunk_filename}"
                    else:
                        upload_path = output_qualified_stage
                        chunk_relative_path = chunk_filename

                    session.file.put(tmp_path, upload_path, auto_compress=False, overwrite=True)

                    chunks_created.append({
                        "filename": chunk_filename, "relative_path": chunk_relative_path, "stage": output_qualified_stage,
                        "start_page": start_page + 1, "end_page": end_page, "page_count": chunk_pages,
                        "size_mb": round(chunk_size_mb, 2), "sequence": chunk_idx + 1
                    })

                if chunks_created:
                    values_list = []
                    for chunk in chunks_created:
                        safe_relative_path = chunk["relative_path"].replace("'", "''")
                        safe_stage = chunk["stage"].replace("'", "''")
                        safe_parent_path = relative_path.replace("'", "''")
                        safe_parent_stage = base_qualified_stage.replace("'", "''")
                        values_list.append(
                            f"(\\'{safe_relative_path}\\', \\'{safe_stage}\\', {chunk['page_count']}, {chunk['size_mb']}, "
                            f"\\'{safe_parent_path}\\', \\'{safe_parent_stage}\\', CURRENT_TIMESTAMP(), "
                            f"\\'Size-based split: Exceeded {max_pages} pages or {max_size_mb}MB limit\\', {chunk['sequence']})"
                        )

                    batch_insert_sql = f"""
                    INSERT INTO {FQN_PREFIX}.DOCUMENT_HIERARCHY
                    (DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOC_PAGES, DOC_SIZE_MB,
                     PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, CREATED_TIMESTAMP, SPLIT_REASON, PARENT_DOCUMENT_SPLIT_SEQUENCE)
                    VALUES {", ".join(values_list)}
                    """
                    session.sql(batch_insert_sql).collect()

            finally:
                import shutil
                if os.path.exists(temp_dir):
                    shutil.rmtree(temp_dir)

            result["chunks_created"] = len(chunks_created)
            result["chunks"] = chunks_created
            result["message"] = f"Successfully split into {len(chunks_created)} chunks"

        result["status"] = "success"
    except Exception as e:
        result["status"] = "error"
        result["message"] = str(e)
    return result


def register_non_pdf_file(session, file_name, base_qualified_stage, subdirectory):
    result = {"status": "success", "original_file": file_name, "original_pages": 0, "original_size_mb": 0,
              "needs_splitting": False, "chunks_created": 0, "message": ""}
    try:
        if subdirectory:
            relative_path = f"{subdirectory}/{file_name}"
        else:
            relative_path = file_name

        if check_document_exists(session, relative_path, base_qualified_stage):
            result["status"] = "skipped"
            result["message"] = f"Document already processed: {relative_path}"
            result["duplicate_detected"] = True
            return result

        insert_sql = f"""
        INSERT INTO {FQN_PREFIX}.DOCUMENT_HIERARCHY (
            DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, DOC_PAGES, DOC_SIZE_MB,
            PARENT_DOCUMENT_RELATIVE_PATH, PARENT_DOCUMENT_STAGE, CREATED_TIMESTAMP, SPLIT_REASON, PARENT_DOCUMENT_SPLIT_SEQUENCE
        ) VALUES (\\\'{relative_path}\\\', \\\'{base_qualified_stage}\\\', NULL, NULL, NULL, NULL, CURRENT_TIMESTAMP(), NULL, NULL)
        """
        session.sql(insert_sql).collect()
        result["message"] = f"Registered non-PDF file: {relative_path}"
    except Exception as e:
        result["status"] = "error"
        result["message"] = str(e)
    return result


def preprocess_handler(session, file_name, stage_name, output_stage, max_pages_per_chunk=125, max_size_mb_per_chunk=100.0):
    max_pages = int(max_pages_per_chunk)
    max_size_mb = float(max_size_mb_per_chunk)

    clean_stage = stage_name.lstrip("@")
    stage_parts = clean_stage.split("/")
    base_stage_name = stage_parts[0]
    subdirectory = "/".join(stage_parts[1:]) if len(stage_parts) > 1 else ""

    if "." not in base_stage_name:
        base_qualified_stage = f"@{FQN_PREFIX}.{base_stage_name}"
    else:
        base_qualified_stage = f"@{base_stage_name}"

    if file_name is None:
        batch_result = {
            "status": "success", "mode": "batch", "stage": stage_name,
            "limits": {"max_pages": max_pages, "max_size_mb": max_size_mb},
            "files_processed": 0, "files_skipped": 0, "files_failed": 0,
            "total_chunks_created": 0, "file_results": []
        }
        try:
            list_stage_sql = f"LIST {stage_name}"
            file_list = session.sql(list_stage_sql).collect()

            pdf_files = []
            non_pdf_files = []
            for row in file_list:
                file_path = row["name"]
                filename = file_path.split("/")[-1]
                if filename.lower().endswith(".pdf"):
                    pdf_files.append(filename)
                elif any(filename.lower().endswith(ext) for ext in SUPPORTED_NON_PDF_EXTENSIONS):
                    non_pdf_files.append(filename)

            batch_result["total_files_found"] = len(pdf_files) + len(non_pdf_files)

            if len(pdf_files) == 0 and len(non_pdf_files) == 0:
                batch_result["message"] = "No supported files found in stage"
                return batch_result

            existing_docs_sql = f"""
            SELECT DOCUMENT_RELATIVE_PATH FROM {FQN_PREFIX}.DOCUMENT_HIERARCHY
            WHERE DOCUMENT_STAGE = \\'{base_qualified_stage}\\'
            """
            existing_docs_result = session.sql(existing_docs_sql).collect()
            existing_docs = set(row["DOCUMENT_RELATIVE_PATH"] for row in existing_docs_result)

            new_pdf_files = []
            for pdf_file in pdf_files:
                if subdirectory:
                    relative_path = f"{subdirectory}/{pdf_file}"
                else:
                    relative_path = pdf_file

                if relative_path in existing_docs:
                    batch_result["files_skipped"] += 1
                    batch_result["file_results"].append({
                        "status": "skipped", "original_file": pdf_file,
                        "message": "Already processed (fast check)", "duplicate_detected": True
                    })
                else:
                    new_pdf_files.append(pdf_file)

            for pdf_file in new_pdf_files:
                try:
                    file_result = process_single_pdf(
                        session, pdf_file, stage_name, output_stage, max_pages, max_size_mb, base_qualified_stage, subdirectory
                    )
                    batch_result["file_results"].append(file_result)

                    if file_result["status"] == "success":
                        batch_result["files_processed"] += 1
                        batch_result["total_chunks_created"] += file_result.get("chunks_created", 0)
                    elif file_result["status"] == "skipped":
                        batch_result["files_skipped"] += 1
                    else:
                        batch_result["files_failed"] += 1
                except Exception as file_error:
                    batch_result["files_failed"] += 1
                    batch_result["file_results"].append({"status": "error", "original_file": pdf_file, "message": str(file_error)})

            for non_pdf_file in non_pdf_files:
                if subdirectory:
                    relative_path = f"{subdirectory}/{non_pdf_file}"
                else:
                    relative_path = non_pdf_file

                if relative_path in existing_docs:
                    batch_result["files_skipped"] += 1
                    batch_result["file_results"].append({
                        "status": "skipped", "original_file": non_pdf_file,
                        "message": "Already processed (fast check)", "duplicate_detected": True
                    })
                    continue

                try:
                    file_result = register_non_pdf_file(session, non_pdf_file, base_qualified_stage, subdirectory)
                    batch_result["file_results"].append(file_result)

                    if file_result["status"] == "success":
                        batch_result["files_processed"] += 1
                    elif file_result["status"] == "skipped":
                        batch_result["files_skipped"] += 1
                    else:
                        batch_result["files_failed"] += 1
                except Exception as file_error:
                    batch_result["files_failed"] += 1
                    batch_result["file_results"].append({"status": "error", "original_file": non_pdf_file, "message": str(file_error)})

            batch_result["message"] = f"Batch processing complete: {batch_result['files_processed']} processed ({len(new_pdf_files)} PDFs, {len(non_pdf_files)} non-PDF), {batch_result['files_skipped']} skipped, {batch_result['files_failed']} failed"
        except Exception as e:
            batch_result["status"] = "error"
            batch_result["message"] = f"Batch processing error: {str(e)}"
        return batch_result
    else:
        single_result = process_single_pdf(session, file_name, stage_name, output_stage, max_pages, max_size_mb, base_qualified_stage, subdirectory)
        single_result["mode"] = "single"
        single_result["limits"] = {"max_pages": max_pages, "max_size_mb": max_size_mb}
        return single_result
$$''';

    -- =========================================================================
    -- 6. CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2
    -- =========================================================================
    EXECUTE IMMEDIATE '
    CREATE OR REPLACE PROCEDURE ' || :v_fqn || '.CLINICAL_DOCUMENTS_PARSE_WITH_IMAGES_V2(
        DOCUMENT_FILTER VARCHAR DEFAULT null,
        FORCE_REPARSE BOOLEAN DEFAULT FALSE
    )
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS OWNER
    AS ''DECLARE
        rows_inserted NUMBER DEFAULT 0;
        docs_to_process NUMBER DEFAULT 0;
    BEGIN
        CREATE OR REPLACE TEMPORARY TABLE TEMP_DOCS_TO_PARSE AS
        WITH classified_docs AS (
            SELECT dcm.DOCUMENT_RELATIVE_PATH,
                   MAX(CASE WHEN dcm.FIELD_NAME ILIKE ''''complex_tables_flag'''' THEN dcm.FIELD_VALUE END) AS complex_tables_flag,
                   MAX(CASE WHEN dcm.FIELD_NAME ILIKE ''''image_flag'''' THEN dcm.FIELD_VALUE END) AS image_flag
            FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
            GROUP BY dcm.DOCUMENT_RELATIVE_PATH
            UNION ALL
            SELECT dh.DOCUMENT_RELATIVE_PATH, ''''NO'''' AS complex_tables_flag, ''''NO'''' AS image_flag
            FROM ' || :v_fqn || '.DOCUMENT_HIERARCHY dh
            WHERE dh.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ' || :v_fqn || '.DOC_CLASSIFICATION_METADATA_ROWS dcm
                              WHERE dcm.DOCUMENT_RELATIVE_PATH = dh.DOCUMENT_RELATIVE_PATH)
        ),
        already_parsed AS (SELECT DISTINCT DOCUMENT_RELATIVE_PATH FROM ' || :v_fqn || '.DOCS_PARSE_OUTPUT),
        parent_documents AS (SELECT DISTINCT PARENT_DOCUMENT_RELATIVE_PATH FROM ' || :v_fqn || '.DOCUMENT_HIERARCHY WHERE PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL)
        SELECT dh.DOCUMENT_RELATIVE_PATH, dh.DOCUMENT_STAGE, dh.PARENT_DOCUMENT_RELATIVE_PATH, dh.PARENT_DOCUMENT_STAGE, dh.DOC_PAGES,
               COALESCE(cd.complex_tables_flag, ''''NO'''') AS complex_tables_flag, COALESCE(cd.image_flag, ''''NO'''') AS image_flag,
               CASE WHEN COALESCE(cd.complex_tables_flag, ''''NO'''') = ''''YES'''' THEN ''''LAYOUT'''' WHEN COALESCE(cd.image_flag, ''''NO'''') = ''''YES'''' THEN ''''LAYOUT'''' ELSE ''''OCR'''' END AS parse_mode,
               CASE WHEN COALESCE(cd.image_flag, ''''NO'''') = ''''YES'''' THEN TRUE ELSE FALSE END AS extract_images,
               CASE WHEN dh.PARENT_DOCUMENT_RELATIVE_PATH IS NOT NULL THEN COALESCE(REGEXP_SUBSTR(dh.DOCUMENT_RELATIVE_PATH, ''''_pages_([0-9]+)_to_'''', 1, 1, ''''e'''', 1)::NUMBER, 1) ELSE 1 END AS start_page_offset
        FROM ' || :v_fqn || '.DOCUMENT_HIERARCHY dh
        LEFT JOIN classified_docs cd ON dh.DOCUMENT_RELATIVE_PATH = cd.DOCUMENT_RELATIVE_PATH
        LEFT JOIN already_parsed ap ON dh.DOCUMENT_RELATIVE_PATH = ap.DOCUMENT_RELATIVE_PATH
        LEFT JOIN parent_documents pd ON dh.DOCUMENT_RELATIVE_PATH = pd.PARENT_DOCUMENT_RELATIVE_PATH
        WHERE (:DOCUMENT_FILTER IS NULL OR dh.DOCUMENT_RELATIVE_PATH = :DOCUMENT_FILTER)
            AND (:FORCE_REPARSE = TRUE OR ap.DOCUMENT_RELATIVE_PATH IS NULL)
            AND pd.PARENT_DOCUMENT_RELATIVE_PATH IS NULL;

        SELECT COUNT(*) INTO :docs_to_process FROM TEMP_DOCS_TO_PARSE;

        IF (docs_to_process = 0) THEN
            DROP TABLE IF EXISTS TEMP_DOCS_TO_PARSE;
            RETURN ''''No new documents to parse - all documents already processed'''';
        END IF;

        CREATE OR REPLACE TEMPORARY TABLE TEMP_PARSED_DOCS AS
        SELECT docs.DOCUMENT_RELATIVE_PATH, docs.DOCUMENT_STAGE, docs.PARENT_DOCUMENT_RELATIVE_PATH, docs.DOC_PAGES,
               docs.parse_mode, docs.extract_images, docs.start_page_offset,
               CASE WHEN docs.parse_mode = ''''LAYOUT'''' AND docs.extract_images = TRUE THEN
                    AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {''''mode'''': ''''LAYOUT'''', ''''page_split'''': true, ''''extract_images'''': true})
               WHEN docs.parse_mode = ''''LAYOUT'''' THEN
                    AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {''''mode'''': ''''LAYOUT'''', ''''page_split'''': true})
               ELSE
                    AI_PARSE_DOCUMENT(TO_FILE(docs.DOCUMENT_STAGE, docs.DOCUMENT_RELATIVE_PATH), {''''mode'''': ''''OCR'''', ''''page_split'''': true})
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
                   AI_EXTRACT(file_data => BASE64_DECODE_BINARY(REGEXP_REPLACE(img.value:image_base64::STRING, ''''^data:image/[^;]+;base64,'''', '''''''')),
                              responseFormat => {''''Image_Description'''': ''''Provide a detailed description of this medical image, including any visible anatomical structures, pathological findings, imaging modality characteristics, and clinically relevant observations.''''}
                   ):response[''''Image_Description'''']::VARCHAR AS image_description
            FROM TEMP_PAGES_EXTRACTED pe, LATERAL FLATTEN(input => pe.page_images) img
            WHERE pe.extract_images = TRUE AND pe.page_images IS NOT NULL AND ARRAY_SIZE(pe.page_images) > 0
        ),
        pages_with_image_array AS (
            SELECT DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, DOC_PAGES,
                   parse_mode, extract_images, PAGE_NUMBER_IN_PARENT, page_content,
                   ARRAY_AGG(OBJECT_CONSTRUCT(''''image_id'''', image_id, ''''description'''', image_description)) WITHIN GROUP (ORDER BY image_index) AS image_data_array
            FROM images_with_descriptions
            GROUP BY DOCUMENT_RELATIVE_PATH, DOCUMENT_STAGE, PARENT_DOCUMENT_RELATIVE_PATH, DOC_PAGES, parse_mode, extract_images, PAGE_NUMBER_IN_PARENT, page_content
        )
        SELECT pe.DOCUMENT_RELATIVE_PATH, pe.DOCUMENT_STAGE, pe.PARENT_DOCUMENT_RELATIVE_PATH, pe.DOC_PAGES,
               pe.parse_mode, pe.extract_images, pe.PAGE_NUMBER_IN_PARENT,
               CASE WHEN pia.image_data_array IS NOT NULL THEN ' || :v_fqn || '.INJECT_IMAGE_DESCRIPTIONS(pe.page_content, pia.image_data_array) ELSE pe.page_content END AS final_page_content
        FROM TEMP_PAGES_EXTRACTED pe
        LEFT JOIN pages_with_image_array pia ON pe.DOCUMENT_RELATIVE_PATH = pia.DOCUMENT_RELATIVE_PATH AND pe.PAGE_NUMBER_IN_PARENT = pia.PAGE_NUMBER_IN_PARENT;

        INSERT INTO ' || :v_fqn || '.DOCS_PARSE_OUTPUT (
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

        RETURN ''''Successfully parsed and inserted '''' || rows_inserted || '''' page(s) from '''' || docs_to_process || '''' document(s)'''';
    END''';

END;
$$;

-- =============================================================================
-- END OF STORED PROCEDURES
-- =============================================================================
