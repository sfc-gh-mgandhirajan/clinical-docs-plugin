import streamlit as st
from snowflake.snowpark.context import get_active_session
import json

session = get_active_session()

st.set_page_config(page_title="Clinical Document Intelligence", layout="wide")
st.title("Clinical Document Intelligence")

SCHEMA = session.sql("SELECT CURRENT_SCHEMA()").collect()[0][0]
DATABASE = session.sql("SELECT CURRENT_DATABASE()").collect()[0][0]

tab_browse, tab_extraction, tab_search, tab_agent, tab_status = st.tabs([
    "Browse", "Extraction Review", "Search", "Agent Chat", "Pipeline Status"
])

with tab_browse:
    st.header("Document Browser")

    doc_types = session.sql(f"""
        SELECT DISTINCT DOCUMENT_CLASSIFICATION 
        FROM {DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_RAW_CONTENT
        WHERE DOCUMENT_CLASSIFICATION IS NOT NULL
        ORDER BY 1
    """).to_pandas()

    selected_type = st.selectbox("Filter by document type", ["All"] + doc_types["DOCUMENT_CLASSIFICATION"].tolist())

    filter_clause = "" if selected_type == "All" else f"WHERE DOCUMENT_CLASSIFICATION = '{selected_type}'"

    docs = session.sql(f"""
        SELECT DISTINCT 
            DOCUMENT_RELATIVE_PATH,
            DOCUMENT_CLASSIFICATION,
            PATIENT_NAME,
            MRN,
            DOC_TOTAL_PAGES
        FROM {DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_RAW_CONTENT
        {filter_clause}
        ORDER BY DOCUMENT_RELATIVE_PATH
        LIMIT 100
    """).to_pandas()

    st.dataframe(docs, use_container_width=True)

    if not docs.empty:
        selected_doc = st.selectbox("Select document to view", docs["DOCUMENT_RELATIVE_PATH"].tolist())
        if selected_doc:
            pages = session.sql(f"""
                SELECT PAGE_NUMBER_IN_PARENT, PAGE_CONTENT
                FROM {DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_RAW_CONTENT
                WHERE DOCUMENT_RELATIVE_PATH = '{selected_doc}'
                ORDER BY PAGE_NUMBER_IN_PARENT
            """).to_pandas()
            for _, row in pages.iterrows():
                st.markdown(f"**Page {row['PAGE_NUMBER_IN_PARENT']}**")
                st.text(row["PAGE_CONTENT"][:2000])
                st.markdown("---")

with tab_extraction:
    st.header("Extraction Review")

    col1, col2 = st.columns(2)

    with col1:
        st.subheader("Classification Distribution")
        class_dist = session.sql(f"""
            SELECT FIELD_VALUE AS DOC_TYPE, COUNT(*) AS COUNT
            FROM {DATABASE}.{SCHEMA}.DOC_CLASSIFICATION_METADATA_ROWS
            WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
            GROUP BY FIELD_VALUE
            ORDER BY COUNT DESC
        """).to_pandas()
        st.bar_chart(class_dist.set_index("DOC_TYPE"))

    with col2:
        st.subheader("Extraction Counts by Type")
        extract_counts = session.sql(f"""
            SELECT DOCUMENT_CLASSIFICATION, COUNT(*) AS FIELD_COUNT
            FROM {DATABASE}.{SCHEMA}.DOC_TYPE_SPECIFIC_VALUES_EXTRACT_OUTPUT
            GROUP BY DOCUMENT_CLASSIFICATION
            ORDER BY FIELD_COUNT DESC
        """).to_pandas()
        st.dataframe(extract_counts, use_container_width=True)

with tab_search:
    st.header("Document Search")

    search_query = st.text_input("Search clinical documents", placeholder="e.g., heart failure treatment plan")

    if search_query:
        results = session.sql(f"""
            SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                '{DATABASE}.{SCHEMA}.CLINICAL_DOCS_SEARCH_SERVICE',
                '{{"query": "{search_query}", "columns": ["page_content", "patient_name", "document_classification", "document_relative_path"], "limit": 5}}'
            ) AS RESULTS
        """).to_pandas()

        if not results.empty:
            search_results = json.loads(results["RESULTS"].iloc[0])
            if "results" in search_results:
                for r in search_results["results"]:
                    st.markdown(f"**{r.get('document_classification', 'Unknown')}** — {r.get('document_relative_path', '')}")
                    st.text(r.get("page_content", "")[:500])
                    st.markdown("---")

with tab_agent:
    st.header("Clinical Documents Agent")
    st.markdown("Ask questions about your clinical documents using natural language.")

    with st.form("agent_form"):
        question = st.text_input("Your question", placeholder="e.g., Which patients were diagnosed with heart failure?")
        submitted = st.form_submit_button("Ask")

    if submitted and question:
        with st.spinner("Querying agent..."):
            try:
                response = session.sql(f"""
                    SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
                        '{DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_AGENT',
                        $$ {{"messages": [{{"role": "user", "content": [{{"type": "text", "text": "{question}"}}]}}]}} $$
                    ) AS RESPONSE
                """).to_pandas()

                if not response.empty:
                    result = json.loads(response["RESPONSE"].iloc[0])
                    if "messages" in result:
                        for msg in result["messages"]:
                            if msg.get("role") == "assistant":
                                for content in msg.get("content", []):
                                    if content.get("type") == "text":
                                        st.markdown(content["text"])
            except Exception as e:
                st.error(f"Agent error: {str(e)}")

with tab_status:
    st.header("Pipeline Status")

    col1, col2, col3 = st.columns(3)

    with col1:
        doc_count = session.sql(f"SELECT COUNT(DISTINCT DOCUMENT_RELATIVE_PATH) FROM {DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_RAW_CONTENT").collect()[0][0]
        st.metric("Documents Processed", doc_count)

    with col2:
        page_count = session.sql(f"SELECT COUNT(*) FROM {DATABASE}.{SCHEMA}.CLINICAL_DOCUMENTS_RAW_CONTENT").collect()[0][0]
        st.metric("Pages Indexed", page_count)

    with col3:
        type_count = session.sql(f"""
            SELECT COUNT(DISTINCT FIELD_VALUE) FROM {DATABASE}.{SCHEMA}.DOC_CLASSIFICATION_METADATA_ROWS
            WHERE FIELD_NAME = 'DOCUMENT_CLASSIFICATION'
        """).collect()[0][0]
        st.metric("Document Types", type_count)

    st.subheader("Task History (Last 24h)")
    task_history = session.sql(f"""
        SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
        FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
            SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
        ))
        WHERE DATABASE_NAME = '{DATABASE}' AND SCHEMA_NAME = '{SCHEMA}'
        ORDER BY SCHEDULED_TIME DESC
        LIMIT 20
    """).to_pandas()
    st.dataframe(task_history, use_container_width=True)
