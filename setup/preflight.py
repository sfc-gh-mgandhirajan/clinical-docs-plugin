#!/usr/bin/env python3
"""
Clinical Document Intelligence Plugin - Preflight Check
Verifies all prerequisites are met before using the plugin.
Run: python3 setup/preflight.py
"""

import os
import sys
import json

try:
    import snowflake.connector
except ImportError:
    print("[FAIL] snowflake-connector-python not installed")
    print("       Run: pip install snowflake-connector-python")
    sys.exit(1)


def get_connection():
    conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME", "default")
    try:
        conn = snowflake.connector.connect(connection_name=conn_name)
        return conn
    except Exception as e:
        print(f"[FAIL] Cannot connect to Snowflake: {e}")
        return None


def check_connection(conn):
    cur = conn.cursor()
    cur.execute("SELECT CURRENT_ACCOUNT(), CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_USER()")
    row = cur.fetchone()
    return {
        "account": row[0],
        "role": row[1],
        "warehouse": row[2],
        "user": row[3],
    }


def check_cortex_ai(conn):
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic', 'Say hello') AS test
        """)
        return True
    except Exception:
        return False


def check_warehouse_size(conn, warehouse_name):
    cur = conn.cursor()
    try:
        cur.execute(f"SHOW WAREHOUSES LIKE '{warehouse_name}'")
        rows = cur.fetchall()
        if rows:
            for row in rows:
                if row[3] in ("Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large"):
                    return True, row[3]
                return False, row[3]
        return False, "NOT FOUND"
    except Exception as e:
        return False, str(e)


def check_database(conn, db_name):
    cur = conn.cursor()
    try:
        cur.execute(f"SHOW DATABASES LIKE '{db_name}'")
        rows = cur.fetchall()
        return len(rows) > 0
    except Exception:
        return False


def check_cortex_search(conn):
    cur = conn.cursor()
    try:
        cur.execute("SHOW CORTEX SEARCH SERVICES")
        return True
    except Exception:
        return False


def check_cke_pubmed(conn):
    try:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM PUBMED_ABSTRACTS_EMBEDDINGS.SHARED.PUBMED_SEARCH_CORPUS LIMIT 1")
        return True
    except Exception:
        return False


def check_dynamic_tables(conn):
    cur = conn.cursor()
    try:
        cur.execute("SHOW DYNAMIC TABLES LIMIT 1")
        return True
    except Exception:
        return False


def run_preflight(target_db=None, target_wh=None):
    print("=" * 60)
    print("  Clinical Document Intelligence Plugin - Preflight Check")
    print("=" * 60)
    print()

    results = []

    # 0. Try reading manifest for defaults
    manifest_db = None
    try:
        import pathlib
        manifest_path = pathlib.Path(__file__).parent.parent / ".deployment" / "manifest.json"
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text())
            manifest_db = manifest.get("environment", {}).get("database")
            if not target_db:
                target_db = manifest_db
                results.append(("Manifest", "OK", f"Read from .deployment/manifest.json (db={target_db})"))
    except Exception:
        pass

    if not target_db:
        target_db = "HCLS_CLINICAL_DOCS"

    results = []

    # 1. Connection
    conn = get_connection()
    if not conn:
        results.append(("Connection", "FAIL", "Cannot connect to Snowflake"))
        print_results(results)
        return False

    ctx = check_connection(conn)
    results.append(("Connection", "OK", f"{ctx['user']}@{ctx['account']} role={ctx['role']}"))
    wh = target_wh or ctx["warehouse"]

    # 2. Cortex AI
    if check_cortex_ai(conn):
        results.append(("Cortex AI", "OK", "AI functions available in this region"))
    else:
        results.append(("Cortex AI", "FAIL", "Cortex AI not available - check region support"))

    # 3. Warehouse Size
    wh_ok, wh_size = check_warehouse_size(conn, wh)
    if wh_ok:
        results.append(("Warehouse", "OK", f"{wh} ({wh_size})"))
    else:
        results.append(("Warehouse", "WARN", f"{wh} is {wh_size} - recommend MEDIUM or larger"))

    # 4. Target Database
    if check_database(conn, target_db):
        results.append(("Target Database", "OK", f"{target_db} exists"))
    else:
        results.append(("Target Database", "SETUP", f"{target_db} not found - will create on provision"))

    # 5. Dynamic Tables support
    if check_dynamic_tables(conn):
        results.append(("Dynamic Tables", "OK", "Feature available"))
    else:
        results.append(("Dynamic Tables", "WARN", "Could not verify - may need account enablement"))

    # 6. Cortex Search
    if check_cortex_search(conn):
        results.append(("Cortex Search", "OK", "Feature available"))
    else:
        results.append(("Cortex Search", "WARN", "Could not verify availability"))

    # 7. CKE PubMed (optional)
    if check_cke_pubmed(conn):
        results.append(("CKE PubMed", "OK", "Marketplace listing installed (literature grounding enabled)"))
    else:
        results.append(("CKE PubMed", "SKIP", "Not installed (optional - literature grounding disabled)"))

    conn.close()
    print_results(results)

    # Determine overall status
    fails = [r for r in results if r[1] == "FAIL"]
    if fails:
        print("\n[!!] PREFLIGHT FAILED - resolve the above issues before proceeding")
        return False
    else:
        print("\n[OK] PREFLIGHT PASSED - ready to use the plugin")
        print("     Run /clinical-docs:extract to start processing documents")
        return True


def print_results(results):
    status_icons = {
        "OK": "[OK]",
        "FAIL": "[!!]",
        "WARN": "[??]",
        "SETUP": "[->]",
        "SKIP": "[--]",
    }
    for name, status, detail in results:
        icon = status_icons.get(status, "[??]")
        print(f"  {icon} {name}: {detail}")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Clinical Docs Plugin Preflight")
    parser.add_argument("--database", default=None, help="Target database name (reads from manifest if not set)")
    parser.add_argument("--warehouse", default=None, help="Target warehouse (uses current if not set)")
    args = parser.parse_args()
    success = run_preflight(target_db=args.database, target_wh=args.warehouse)
    sys.exit(0 if success else 1)
