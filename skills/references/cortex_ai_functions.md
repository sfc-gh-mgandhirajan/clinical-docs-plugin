# Cortex AI Functions Reference — Clinical Documents

## AI_PARSE_DOCUMENT

Multimodal document parsing. Converts document pages to structured text.

### Modes
| Mode | When to Use | Features |
|------|-------------|----------|
| `OCR` | Standard text documents | Fast, text-focused |
| `LAYOUT` | Documents with tables, forms, or images | Preserves structure, supports image extraction |

### Syntax
```sql
AI_PARSE_DOCUMENT(
    TO_FILE(stage, path),
    {'mode': 'LAYOUT', 'page_split': true, 'extract_images': true}
)
```

### Output Structure
```json
{
  "pages": [
    {"content": "...", "images": [{"id": "img_1", "image_base64": "..."}]}
  ]
}
```

## AI_EXTRACT

Extracts structured fields from files using natural language prompts.

### Config-Driven Pattern
```sql
AI_EXTRACT(
    file => TO_FILE(stage, path),
    responseFormat => BUILD_DOC_TYPE_EXTRACTION_JSON(doc_type)
)
```

The `responseFormat` is dynamically built from `{db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG`:
```sql
SELECT OBJECT_AGG(FIELD_NAME, TO_VARIANT(EXTRACTION_QUESTION))
FROM {db}.{schema}.DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG
WHERE DOCUMENT_CLASSIFICATION ILIKE doc_type AND IS_ACTIVE = TRUE;
```

### Output Structure
```json
{"response": {"MRN": "12345", "PATIENT_NAME": "John Doe", ...}}
```

## AI_AGG

Aggregates content from multiple rows (pages) and answers a question across all of them. Used for split documents where no single page has the complete answer.

### Classification Pattern
```sql
AI_AGG(page_content, 'How would you classify this document?')
```
Groups by parent document to classify across all pages.

The classification question is dynamically built from `CLINICAL_DOCS_EXTRACTION_CONFIG` using LISTAGG with `, OTHER)` appended. `OTHER` is always a valid response — the pipeline detects OTHER documents after classification and offers an interactive onboarding workflow (see extraction SKILL.md Step 4.2c).

### Extraction Pattern
```sql
AI_AGG(page_content, '{dynamically_built_extraction_prompt}')
```
The extraction prompt is built dynamically at runtime from `DOC_TYPE_SPECIFIC_EXTRACTION_CONFIG` using `LISTAGG`, not hardcoded. Returns JSON with extracted values from the entire document.

## AI_EXTRACT on Binary (Image Description)

Used to generate descriptions for extracted images:
```sql
AI_EXTRACT(
    file_data => BASE64_DECODE_BINARY(image_base64),
    responseFormat => {'Image_Description': 'Provide a detailed description of this medical image...'}
)
```

## Decision Tree: Which Function to Use

```
Is the document a single file (PDF < 125 pages, or non-PDF)?
├─ YES → AI_EXTRACT for classification and field extraction
│        AI_PARSE_DOCUMENT for page-level content
└─ NO  → Split into chunks first (PREPROCESS_CLINICAL_DOCS)
         AI_PARSE_DOCUMENT on each chunk for page content
         AI_AGG across all chunks for classification
         AI_AGG across all chunks for field extraction
```
