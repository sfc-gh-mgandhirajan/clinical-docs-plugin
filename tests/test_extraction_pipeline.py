#!/usr/bin/env python3
"""
Clinical Document Intelligence Plugin - Extraction Pipeline Test
Validates the full pipeline using synthetic documents (no real PHI).
"""

import os
import sys
import json

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE_DIR = os.path.join(PLUGIN_ROOT, "tests", "sample_documents")

EXPECTED_RESULTS = {
    "synthetic_discharge_summary_001.txt": {
        "document_type": "discharge_summary",
        "expected_diagnoses": [
            "Acute decompensated heart failure",
            "Coronary artery disease",
            "Type 2 diabetes mellitus",
            "Bilateral pleural effusions",
        ],
        "expected_medications": [
            "Furosemide",
            "Lisinopril",
            "Carvedilol",
            "Metformin",
            "Aspirin",
            "Atorvastatin",
        ],
        "expected_sections": [
            "CHIEF COMPLAINT",
            "HISTORY OF PRESENT ILLNESS",
            "HOSPITAL COURSE",
            "DIAGNOSES",
            "MEDICATIONS AT DISCHARGE",
            "FOLLOW-UP",
        ],
    },
    "synthetic_radiology_report_001.txt": {
        "document_type": "radiology_report",
        "expected_findings": [
            "spiculated nodule",
            "right upper lobe",
            "2.3cm",
        ],
        "expected_sections": [
            "CLINICAL INDICATION",
            "TECHNIQUE",
            "FINDINGS",
            "IMPRESSION",
        ],
    },
    "synthetic_pathology_report_001.txt": {
        "document_type": "pathology_report",
        "expected_findings": [
            "invasive ductal carcinoma",
            "grade 2",
            "ER: Positive",
            "HER2: Negative",
        ],
        "expected_sections": [
            "CLINICAL HISTORY",
            "GROSS DESCRIPTION",
            "MICROSCOPIC DESCRIPTION",
            "IMMUNOHISTOCHEMISTRY",
            "DIAGNOSIS",
        ],
    },
}


def validate_classification(conn, doc_id, expected_type):
    cur = conn.cursor()
    cur.execute(f"""
        SELECT DOCUMENT_TYPE, CONFIDENCE_SCORE 
        FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.CLASSIFIED_DOCUMENTS 
        WHERE DOC_ID = '{doc_id}'
    """)
    row = cur.fetchone()
    if not row:
        return False, "No classification found"
    if row[0].lower() != expected_type.lower():
        return False, f"Expected '{expected_type}', got '{row[0]}'"
    return True, f"Classified as '{row[0]}' (confidence: {row[1]:.2f})"


def validate_extraction(conn, doc_id, expected_fields):
    cur = conn.cursor()
    cur.execute(f"""
        SELECT FIELD_NAME, FIELD_VALUE 
        FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.EXTRACTED_FIELDS 
        WHERE DOC_ID = '{doc_id}'
    """)
    rows = cur.fetchall()
    extracted_values = [row[1] for row in rows]
    found = []
    missing = []
    for expected in expected_fields:
        if any(expected.lower() in v.lower() for v in extracted_values):
            found.append(expected)
        else:
            missing.append(expected)
    return found, missing


def validate_sections(conn, doc_id, expected_sections):
    cur = conn.cursor()
    cur.execute(f"""
        SELECT SECTION_NAME 
        FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.PARSED_SECTIONS 
        WHERE DOC_ID = '{doc_id}'
        ORDER BY SECTION_ORDER
    """)
    rows = cur.fetchall()
    parsed_sections = [row[0] for row in rows]
    found = []
    missing = []
    for expected in expected_sections:
        if any(expected.lower() in s.lower() for s in parsed_sections):
            found.append(expected)
        else:
            missing.append(expected)
    return found, missing


def run_tests(conn):
    print("=" * 60)
    print("  Clinical Docs Plugin - Extraction Pipeline Test")
    print("=" * 60)
    print()

    total_checks = 0
    passed_checks = 0

    for filename, expectations in EXPECTED_RESULTS.items():
        print(f"\n  Document: {filename}")
        print(f"  {'=' * 50}")

        cur = conn.cursor()
        cur.execute(f"""
            SELECT DOC_ID FROM HCLS_CLINICAL_DOCS.CLINICAL_DOCS.RAW_DOCUMENTS 
            WHERE FILE_NAME = '{filename}'
        """)
        row = cur.fetchone()
        if not row:
            print(f"  [SKIP] Document not found in RAW_DOCUMENTS (not yet ingested)")
            continue

        doc_id = row[0]

        # Test classification
        total_checks += 1
        ok, msg = validate_classification(conn, doc_id, expectations["document_type"])
        status = "[PASS]" if ok else "[FAIL]"
        if ok:
            passed_checks += 1
        print(f"  {status} Classification: {msg}")

        # Test extraction
        extract_key = None
        for key in ["expected_diagnoses", "expected_medications", "expected_findings"]:
            if key in expectations:
                extract_key = key
                break

        if extract_key:
            total_checks += 1
            found, missing = validate_extraction(conn, doc_id, expectations[extract_key])
            if not missing:
                passed_checks += 1
                print(f"  [PASS] Extraction: {len(found)}/{len(found)} fields found")
            else:
                print(f"  [FAIL] Extraction: {len(found)}/{len(found)+len(missing)} found, missing: {missing}")

        # Test section parsing
        if "expected_sections" in expectations:
            total_checks += 1
            found, missing = validate_sections(conn, doc_id, expectations["expected_sections"])
            if not missing:
                passed_checks += 1
                print(f"  [PASS] Sections: {len(found)}/{len(found)} sections parsed")
            else:
                print(f"  [FAIL] Sections: {len(found)}/{len(found)+len(missing)} found, missing: {missing}")

    print(f"\n{'=' * 60}")
    print(f"  Results: {passed_checks}/{total_checks} checks passed")
    print(f"{'=' * 60}")
    return passed_checks == total_checks


if __name__ == "__main__":
    import snowflake.connector
    conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "default")
    try:
        conn = snowflake.connector.connect(connection_name=conn_name)
        success = run_tests(conn)
        conn.close()
        sys.exit(0 if success else 1)
    except Exception as e:
        print(f"[ERROR] {e}")
        print("Note: Tests require the extraction pipeline to have been run first.")
        print("Run /clinical-docs:extract on the sample documents before testing.")
        sys.exit(1)
