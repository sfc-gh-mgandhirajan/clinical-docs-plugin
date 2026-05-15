-- =============================================================================
-- PREPROCESS_CLINICAL_DOCS (Python)
-- Splits large PDFs and registers all file types in DOCUMENT_HIERARCHY.
-- Replace {db}, {schema}, and {stage} with actual values before execution.
--
-- QUOTING NOTE: This procedure uses simple f-string quoting ('{value}')
-- for SQL string literals. Values with embedded single quotes are handled
-- via .replace("'", "''") before interpolation.
-- =============================================================================
CREATE OR REPLACE PROCEDURE {db}.{schema}.PREPROCESS_CLINICAL_DOCS(
    FILE_NAME VARCHAR DEFAULT null,
    STAGE_NAME VARCHAR DEFAULT '@{db}.{schema}.{stage}',
    OUTPUT_STAGE VARCHAR DEFAULT '@{db}.{schema}.{stage}/processed',
    MAX_PAGES_PER_CHUNK NUMBER(38,0) DEFAULT 125,
    MAX_SIZE_MB_PER_CHUNK FLOAT DEFAULT 100
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','PyPDF2')
HANDLER = 'preprocess_handler'
EXECUTE AS CALLER
AS $$
from PyPDF2 import PdfReader, PdfWriter
from snowflake.snowpark.files import SnowflakeFile
from io import BytesIO
import tempfile
import os
import json

FQN_PREFIX = "{db}.{schema}"
SUPPORTED_NON_PDF_EXTENSIONS = (".docx", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".txt")

def _safe(value):
    """Escape single quotes for SQL string interpolation."""
    return str(value).replace("'", "''") if value else value

def check_document_exists(session, relative_path, stage):
    check_sql = f"""
    SELECT COUNT(*) as COUNT FROM {FQN_PREFIX}.DOCUMENT_HIERARCHY
    WHERE DOCUMENT_RELATIVE_PATH = '{_safe(relative_path)}' AND DOCUMENT_STAGE = '{_safe(stage)}'
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

        file_url_sql = f"SELECT build_scoped_file_url('{_safe(full_qualified_stage)}', '{_safe(file_name)}')"
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
        ) VALUES ('{_safe(relative_path)}', '{_safe(base_qualified_stage)}', {total_pages}, {round(total_size_mb, 2)}, NULL, NULL, CURRENT_TIMESTAMP(), NULL, NULL)
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
                        values_list.append(
                            f"('{_safe(chunk['relative_path'])}', '{_safe(chunk['stage'])}', {chunk['page_count']}, {chunk['size_mb']}, "
                            f"'{_safe(relative_path)}', '{_safe(base_qualified_stage)}', CURRENT_TIMESTAMP(), "
                            f"'Size-based split: Exceeded {max_pages} pages or {max_size_mb}MB limit', {chunk['sequence']})"
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
        ) VALUES ('{_safe(relative_path)}', '{_safe(base_qualified_stage)}', NULL, NULL, NULL, NULL, CURRENT_TIMESTAMP(), NULL, NULL)
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
            WHERE DOCUMENT_STAGE = '{_safe(base_qualified_stage)}'
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
$$;
