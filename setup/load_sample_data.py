#!/usr/bin/env python3
"""
Clinical Document Intelligence Plugin - Sample Data Loader
Loads synthetic clinical documents into the plugin stage for testing.
No real PHI is used - all documents are AI-generated synthetic data.
"""

import os
import sys

SAMPLE_DOCS_DIR = os.path.join(os.path.dirname(__file__), "..", "tests", "sample_documents")

SYNTHETIC_DISCHARGE_SUMMARY = """DISCHARGE SUMMARY

Patient: Jane Doe (SYNTHETIC - NOT A REAL PATIENT)
MRN: SYN-2024-001
DOB: 01/15/1955
Admission Date: 03/10/2024
Discharge Date: 03/15/2024
Attending Physician: Dr. Smith (Synthetic)

CHIEF COMPLAINT: Shortness of breath, chest pain

HISTORY OF PRESENT ILLNESS:
71-year-old female presented with progressive dyspnea and substernal chest pain 
for 3 days. Patient has history of CHF (EF 35%), CAD s/p CABG 2019, and Type 2 
diabetes mellitus.

HOSPITAL COURSE:
Patient was admitted to telemetry. BNP elevated at 1,847. Chest X-ray showed 
bilateral pleural effusions. Started on IV furosemide with good diuresis. 
Echocardiogram showed EF 30% (decreased from 35% baseline).
Cardiology consulted - recommended uptitration of heart failure medications.

DIAGNOSES:
1. Acute decompensated heart failure (ICD-10: I50.21)
2. Coronary artery disease (ICD-10: I25.10)
3. Type 2 diabetes mellitus (ICD-10: E11.9)
4. Bilateral pleural effusions (ICD-10: J91.8)

MEDICATIONS AT DISCHARGE:
1. Furosemide 40mg PO BID
2. Lisinopril 10mg PO daily
3. Carvedilol 12.5mg PO BID
4. Metformin 1000mg PO BID
5. Aspirin 81mg PO daily
6. Atorvastatin 40mg PO daily

FOLLOW-UP:
- Cardiology clinic in 1 week
- PCP follow-up in 2 weeks
- Daily weights, fluid restriction 1.5L/day
"""

SYNTHETIC_RADIOLOGY_REPORT = """RADIOLOGY REPORT

Patient: John Smith (SYNTHETIC - NOT A REAL PATIENT)
MRN: SYN-2024-002
DOB: 08/22/1968
Exam Date: 04/05/2024
Exam: CT Chest with contrast

CLINICAL INDICATION: Persistent cough, weight loss. Rule out malignancy.

TECHNIQUE: CT chest with IV contrast, 1.25mm axial images reconstructed.

FINDINGS:
Lungs: 2.3cm spiculated nodule in the right upper lobe (series 4, image 67). 
No other pulmonary nodules identified. No pleural effusion.
Mediastinum: No significant lymphadenopathy. Heart size normal.
Bones: No lytic or blastic lesions.

IMPRESSION:
1. 2.3cm spiculated right upper lobe nodule, suspicious for primary lung 
   malignancy. Recommend PET-CT for further evaluation.
2. No mediastinal lymphadenopathy.
3. No pleural effusion.

Reported by: Dr. Johnson (Synthetic), Board Certified Radiologist
"""

SYNTHETIC_PATHOLOGY_REPORT = """SURGICAL PATHOLOGY REPORT

Patient: Maria Garcia (SYNTHETIC - NOT A REAL PATIENT)
MRN: SYN-2024-003
DOB: 05/30/1972
Collection Date: 04/12/2024
Report Date: 04/15/2024

SPECIMEN: Right breast, excisional biopsy

CLINICAL HISTORY: 52-year-old female with palpable right breast mass identified 
on screening mammography. BI-RADS 5.

GROSS DESCRIPTION:
Received fresh, a 4.2 x 3.1 x 2.8 cm tan-white firm mass with irregular margins.

MICROSCOPIC DESCRIPTION:
Sections show invasive ductal carcinoma, grade 2 (Nottingham score 6/9: 
tubule formation 2, nuclear pleomorphism 2, mitotic count 2). Tumor measures 
2.8cm in greatest dimension. No lymphovascular invasion identified. 
Surgical margins negative (closest margin 3mm, medial).

IMMUNOHISTOCHEMISTRY:
- ER: Positive (95%, strong)
- PR: Positive (80%, moderate)  
- HER2: Negative (IHC 1+)
- Ki-67: 15%

DIAGNOSIS:
Invasive ductal carcinoma, grade 2, ER+/PR+/HER2-
Tumor size: 2.8 cm (pT2)
Margins: Negative
Lymphovascular invasion: Not identified

Pathologist: Dr. Williams (Synthetic), MD
"""


def create_sample_documents():
    os.makedirs(SAMPLE_DOCS_DIR, exist_ok=True)

    docs = {
        "synthetic_discharge_summary_001.txt": SYNTHETIC_DISCHARGE_SUMMARY,
        "synthetic_radiology_report_001.txt": SYNTHETIC_RADIOLOGY_REPORT,
        "synthetic_pathology_report_001.txt": SYNTHETIC_PATHOLOGY_REPORT,
    }

    for filename, content in docs.items():
        filepath = os.path.join(SAMPLE_DOCS_DIR, filename)
        with open(filepath, "w") as f:
            f.write(content)
        print(f"  Created: {filepath}")

    print(f"\n  {len(docs)} synthetic documents created in {SAMPLE_DOCS_DIR}")
    print("  NOTE: These contain NO real PHI - all data is AI-generated synthetic.")
    return list(docs.keys())


def upload_to_stage(conn, stage_name=None, db=None, schema=None):
    import pathlib
    manifest_path = pathlib.Path(__file__).parent.parent / ".deployment" / "manifest.json"
    if manifest_path.exists() and (not db or not schema or not stage_name):
        manifest = json.loads(manifest_path.read_text())
        env = manifest.get("environment", {})
        db = db or env.get("database", "HCLS_CLINICAL_DOCS")
        schema = schema or env.get("schema", "CLINICAL_DOCS")
        stage_name = stage_name or env.get("stage", "CLINICAL_DOCS_STAGE")
    else:
        db = db or "HCLS_CLINICAL_DOCS"
        schema = schema or "CLINICAL_DOCS"
        stage_name = stage_name or "CLINICAL_DOCS_STAGE"

    cur = conn.cursor()
    cur.execute(f"USE DATABASE {db}")
    cur.execute(f"USE SCHEMA {schema}")

    for filename in os.listdir(SAMPLE_DOCS_DIR):
        filepath = os.path.join(SAMPLE_DOCS_DIR, filename)
        if os.path.isfile(filepath):
            cur.execute(f"PUT file://{filepath} @{stage_name}/{filename} AUTO_COMPRESS=FALSE OVERWRITE=TRUE")
            print(f"  Uploaded: {filename} -> @{stage_name}")

    cur.execute(f"LIST @{stage_name}")
    rows = cur.fetchall()
    print(f"\n  Stage @{stage_name} now contains {len(rows)} files")


if __name__ == "__main__":
    print("=" * 60)
    print("  Clinical Docs Plugin - Sample Data Loader")
    print("=" * 60)
    print()

    print("Step 1: Creating synthetic documents...")
    create_sample_documents()

    print("\nStep 2: Upload to Snowflake stage? (requires active connection)")
    if "--upload" in sys.argv:
        import snowflake.connector
        conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "default")
        conn = snowflake.connector.connect(connection_name=conn_name)
        upload_to_stage(conn)
        conn.close()
    else:
        print("  Skipped (run with --upload to push to Snowflake stage)")

    print("\nDone.")
