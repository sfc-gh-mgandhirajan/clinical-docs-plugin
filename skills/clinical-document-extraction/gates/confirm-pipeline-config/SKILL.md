---
name: confirm-pipeline-config
parent_skill: clinical-document-extraction
description: "Tier-1 gate micro-skill. Confirms pipeline execution mode, warehouse sizing, and pricing with the user. Returns {mode}, {warehouse_size_decision}, {estimated_cost}, {user_approved_cost}. Requires {db}, {schema}, {stage}, {warehouse}, {file_count} from previous gates."
tools: ["snowflake_sql_execute", "ask_user_question"]
---

# Gate: Confirm Pipeline Config

This gate micro-skill confirms pipeline execution mode, warehouse sizing, and cost estimates with the user. It covers GATE E6, GATE E6b, and GATE E7 from the extraction pipeline.

**This skill MUST complete and return before any pipeline phase executes.**

## Inputs (from previous gates)

| Parameter | Source |
|-----------|--------|
| `{db}` | confirm-environment |
| `{schema}` | confirm-environment |
| `{stage}` | confirm-environment |
| `{warehouse}` | confirm-environment |
| `{file_count}` | confirm-environment |
| `{configured_types}` | confirm-doc-types |

## Outputs (returned to caller)

| Parameter | Example | Description |
|-----------|---------|-------------|
| `{mode}` | `full` | Pipeline execution mode |
| `{warehouse_size_decision}` | `auto-resize` | Warehouse sizing strategy |
| `{estimated_cost}` | `~2.5 credits` | Total estimated cost |
| `{user_approved_cost}` | `true` | User explicitly approved cost |

---

## 🛑 MANDATORY STOP — GATE E6: Pipeline Mode Selection

Use `ask_user_question` to ask: "How would you like to run the pipeline?"

**DO NOT default to Full Pipeline without asking.**

| Mode | Description | Recommendation |
|------|-------------|---------------|
| **Full Pipeline** | Run all steps sequentially (classify → extract → parse → refresh) | Best for first-time processing |
| **Step-by-Step** | Execute one step at a time with intermediate review | Best for debugging or new doc types |
| **Single Step** | Run a specific step only | Best for reprocessing or incremental |

**Recommend**: "For first-time setup, I recommend Full Pipeline. For a new document type, I recommend Step-by-Step so you can review extraction quality."

---

## 🛑 MANDATORY STOP — GATE E6b: Warehouse Sizing Confirmation

Check current warehouse size:
```sql
SHOW WAREHOUSES LIKE '{warehouse}';
```

Present the sizing recommendation:

| Step | Recommended Size | Rationale |
|------|-----------------|-----------|
| Preprocess | Medium | PDF splitting is I/O-bound |
| Classify/Extract | 3X-Large | AI_EXTRACT processes full documents |
| Parse | 3X-Large | AI_PARSE_DOCUMENT is compute-intensive |
| AI_AGG steps | X-Large | Aggregation across pages |
| Refresh task | Medium | INSERT/UPDATE operations |

Use `ask_user_question` to ask: "Your current warehouse is {warehouse} ({current_size}). The pipeline recommends up to 3X-Large for parse/extract steps. How should I handle warehouse sizing?"

Options:
- **Auto-resize**: Resize to recommended size per step, restore original size when done
- **Keep current size**: Use `{warehouse}` at its current size (may be slower for large document sets)
- **Use different warehouse**: Specify a different warehouse for pipeline execution

If auto-resize selected, the pipeline will run:
```sql
ALTER WAREHOUSE {warehouse} SET WAREHOUSE_SIZE = '{recommended_size}';
```
before each step group and restore the original size after completion.

---

## 🛑 MANDATORY STOP — GATE E7: Pricing Confirmation

Count files and estimate page volume:
```sql
SELECT COUNT(*) AS file_count,
       SUM(SIZE) / (1024*1024) AS total_size_mb
FROM DIRECTORY(@{db}.{schema}.{stage})
WHERE RELATIVE_PATH LIKE '%.pdf';
```

Present cost breakdown per pipeline step:

| Step | AI Function | Pricing | Estimated Cost |
|------|------------|---------|----------------|
| Preprocess | N/A (Python) | Warehouse compute only | {wh_cost} |
| Classify | AI_EXTRACT | 5 credits / 1M tokens | ~{classify_cost} credits |
| Extract | AI_EXTRACT | 5 credits / 1M tokens | ~{extract_cost} credits |
| Parse | AI_PARSE_DOCUMENT | OCR: 0.5 / LAYOUT: 3.33 per 1K pages | ~{parse_cost} credits |
| AI_AGG | AI_AGG | Token-based | ~{agg_cost} credits |
| **Total** | | | **~{total} credits** |

Use `ask_user_question` to confirm: "Estimated cost is ~{total} credits for {file_count} documents. Shall I proceed?"

**DO NOT execute any pipeline steps until pricing is confirmed.**

> **Pricing formulas from `document-intelligence`:**
> - AI_EXTRACT: `cost = tokens × (5 / 1,000,000)` (~4 chars ≈ 1 token)
> - AI_PARSE_DOCUMENT OCR: `cost = pages × 0.0005`
> - AI_PARSE_DOCUMENT LAYOUT: `cost = pages × 0.00333`

---

## Return

After all three gates complete, return the confirmed config:

```
GATE COMPLETE: confirm-pipeline-config
  mode: {mode}
  warehouse_size_decision: {warehouse_size_decision}
  estimated_cost: {estimated_cost}
  user_approved_cost: true
```

**DO NOT proceed to pipeline execution. Return to caller.**
