
#!/usr/bin/env python3
"""
upload_to_snowflake.py

Description:
    Bulk uploads MIMIC-IV dataset CSV files to Snowflake data warehouse.
    Handles large files by reading and uploading data in chunks to avoid
    memory errors. Includes validation to ensure data completeness and
    skips tables that already exist in the warehouse.

Usage:
    python upload_to_snowflake.py

Requirements:
    - MIMIC-IV dataset downloaded locally
    - .env file with Snowflake credentials:
        SNOWFLAKE_USER
        SNOWFLAKE_PAT (Personal Access Token)
        SNOWFLAKE_ACCOUNT
        SNOWFLAKE_WAREHOUSE
        SNOWFLAKE_DATABASE

Author:
    Created for MIMIC-IV RWE analysis

Dependencies:
    - pandas
    - snowflake-connector-python
    - python-dotenv
"""

import os
from pathlib import Path
import glob
import gzip
import pandas as pd
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas
from dotenv import load_dotenv

load_dotenv()

# ── config ────────────────────────────────────────────────────────────────────
# update this to wherever you downloaded MIMIC-IV

cwd = os.getcwd()
print(f"Current working directory: {cwd}")

# change cwd to the script's directory to ensure relative paths work
script_dir = os.path.dirname(os.path.abspath(__file__))

MIMIC_BASE_DIR = "./physionet.org/files/mimiciv/3.1"

TABLES = {
    "HOSP": [
        "patients",
        "admissions",
        "diagnoses_icd",
        "d_icd_diagnoses",
        "d_icd_procedures",
        # "pharmacy",
        "prescriptions",
        "labevents",
        "d_labitems",
        "transfers",
        "services",
    ],
    "ICU": [
        "icustays",
        "inputevents",
        "outputevents",
        "chartevents",  # warning: very large ~30GB uncompressed
        "d_items",
        "procedureevents",
    ],
}

# ── connection ────────────────────────────────────────────────────────────────
conn = snowflake.connector.connect(
    user=os.getenv("SNOWFLAKE_USER"),
    password=os.getenv("SNOWFLAKE_PAT"),
    account=os.getenv("SNOWFLAKE_ACCOUNT"),
    warehouse=os.getenv("SNOWFLAKE_WAREHOUSE"),
    database=os.getenv("SNOWFLAKE_DATABASE"),
)

cursor = conn.cursor()


def setup_schemas():
    cursor.execute("CREATE DATABASE IF NOT EXISTS MIMIC_IV")
    cursor.execute("USE DATABASE MIMIC_IV")
    cursor.execute("CREATE SCHEMA IF NOT EXISTS HOSP")
    cursor.execute("CREATE SCHEMA IF NOT EXISTS ICU")
    print("[OK] Schemas created: MIMIC_IV.HOSP, MIMIC_IV.ICU")


def table_exists(schema: str, table_name: str) -> bool:
    """Check if a table already exists in Snowflake."""
    try:
        cursor.execute(f"SELECT EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table_name.upper()}')")
        result = cursor.fetchone()
        return result[0] if result else False
    except Exception as e:
        print(f"  [WARNING] Error checking table existence: {e}")
        return False


def count_csv_rows(filepath: str) -> int:
    """Count rows in a gzipped CSV file."""
    try:
        count = sum(1 for _ in gzip.open(filepath, 'rt')) - 1  # subtract 1 for header
        return count
    except Exception as e:
        print(f"  [WARNING] Error counting CSV rows: {e}")
        return -1


def get_table_row_count(schema: str, table_name: str) -> int:
    """Get row count from Snowflake table."""
    try:
        cursor.execute(f"SELECT COUNT(*) FROM {schema}.{table_name.upper()}")
        result = cursor.fetchone()
        return result[0] if result else 0
    except Exception as e:
        print(f"  [WARNING] Error getting table row count: {e}")
        return -1


def validate_upload(schema: str, table_name: str, filepath: str) -> bool:
    """Validate that uploaded table has same row count as source CSV."""
    expected_rows = count_csv_rows(filepath)
    actual_rows = get_table_row_count(schema, table_name)
    
    if expected_rows == -1 or actual_rows == -1:
        print(f"  [WARNING] Could not validate upload (error reading counts)")
        return False
    
    if expected_rows == actual_rows:
        print(f"  [OK] Validation passed: {actual_rows:,} rows match CSV")
        return True
    else:
        print(f"  [ERROR] Validation FAILED: Expected {expected_rows:,} rows, got {actual_rows:,}")
        return False


def upload_table(schema: str, table_name: str, filepath: str):
    print(f"\nUploading {schema}.{table_name}...")
    print(f"  Reading {filepath} in chunks...")

    cursor.execute(f"USE SCHEMA {schema}")

    chunk_size = 500000
    total_rows = 0
    table_created = False

    # pandas reads .csv.gz natively — no unzipping needed
    # Read in chunks to avoid memory issues with large files
    for chunk in pd.read_csv(filepath, compression="gzip", chunksize=chunk_size, dtype=str):
        # snowflake wants uppercase column names
        chunk.columns = [c.upper() for c in chunk.columns]
        
        # reset index to standard RangeIndex to avoid Snowflake warnings
        chunk = chunk.reset_index(drop=True)

        mode = "overwrite" if not table_created else "append"
        
        success, nchunks, nrows, _ = write_pandas(
            conn=conn,
            df=chunk,
            table_name=table_name.upper(),
            auto_create_table=True,  # creates table from first chunk
            overwrite=(mode == "overwrite"),
            quote_identifiers=False,
        )

        if success:
            total_rows += nrows
            table_created = True
            print(f"  Chunk uploaded: {nrows:,} rows")
        else:
            print(f"  [ERROR] Chunk failed — check connection and permissions")
            return

    print(f"  [OK] Total uploaded: {total_rows:,} rows")
    
    # Validate that all rows were uploaded successfully
    validate_upload(schema, table_name, filepath)


def main():
    setup_schemas()

    for schema, tables in TABLES.items():
        module_dir = os.path.join(MIMIC_BASE_DIR, schema.lower())

        for table in tables:
            filepath = os.path.join(module_dir, f"{table}.csv.gz")
            filepath = Path(filepath).resolve()  # convert to absolute path

            if not os.path.exists(filepath):
                print(f"  [WARNING] Not found, skipping: {filepath}")
                continue
            
            # Skip if table already exists in Snowflake
            if table_exists(schema, table):
                print(f"\n[OK] {schema}.{table} already exists, checking row count...")
                if validate_upload(schema, table, filepath): 
                    print(f"  Skipping upload for {schema}.{table}")
                    continue
                else: 
                    print(f"  Row count mismatch for existing table {schema}.{table}, re-uploading...")
                    upload_table(schema, table, filepath)
                continue

            upload_table(schema, table, filepath)


if __name__ == "__main__":
    main()
