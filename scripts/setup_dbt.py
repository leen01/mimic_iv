import os
import subprocess
from pathlib import Path
import snowflake.connector
from dotenv import load_dotenv, dotenv_values

ROOT_DIR = Path(__file__).resolve().parent.parent
DOTENV_PATH = ROOT_DIR / ".env"
load_dotenv(dotenv_path=DOTENV_PATH)

# ── step 1: create MARTS schema in Snowflake ──────────────────────────────────
# dbt will create tables inside this schema when it runs mart models


def setup_marts_schema():
    print("Setting up MARTS schema...")

    conn = snowflake.connector.connect(
        user=os.getenv("SNOWFLAKE_USER"),
        password=os.getenv("SNOWFLAKE_PAT"),
        account=os.getenv("SNOWFLAKE_ACCOUNT"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE"),
        database="MIMIC_IV",
    )

    cursor = conn.cursor()
    cursor.execute("CREATE SCHEMA IF NOT EXISTS MIMIC_IV.MARTS")
    print("  ✓ MIMIC_IV.MARTS schema ready")

    # verify all expected schemas exist
    cursor.execute("SHOW SCHEMAS IN DATABASE MIMIC_IV")
    schemas = [row[1] for row in cursor.fetchall()]
    print(f"  Schemas in MIMIC_IV: {schemas}")

    for required in ["HOSP", "ICU", "MARTS"]:
        if required in schemas:
            print(f"  ✓ {required}")
        else:
            print(
                f"  ✗ {required} — missing, check upload_to_snowflake.py ran correctly"
            )

    cursor.close()
    conn.close()


# ── step 2: run dbt commands ──────────────────────────────────────────────────


def run_dbt(command: list[str]) -> bool:
    """Run a dbt command and return True if it succeeded."""
    full_command = ["poetry", "run", "dbt"] + command
    print(f"\nRunning: {' '.join(full_command)}")
    print("-" * 60)

    env = os.environ.copy()
    env.update(dotenv_values(DOTENV_PATH))

    result = subprocess.run(
        full_command,
        cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        env=env,
        capture_output=False,  # stream output directly to terminal
    )

    success = result.returncode == 0
    if success:
        print(f"✓ dbt {' '.join(command)} succeeded")
    else:
        print(f"✗ dbt {' '.join(command)} failed — see output above")

    return success


# ── step 3: verify tables exist ───────────────────────────────────────────────


def verify_tables():
    print("\nVerifying mart tables...")

    conn = snowflake.connector.connect(
        user=os.getenv("SNOWFLAKE_USER"),
        password=os.getenv("SNOWFLAKE_PAT"),
        account=os.getenv("SNOWFLAKE_ACCOUNT"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE"),
        database="MIMIC_IV",
        schema="MARTS",
    )

    cursor = conn.cursor()

    expected_tables = [
        ("HOSP", "STG_PATIENTS"),
        ("HOSP", "STG_ADMISSIONS"),
        ("HOSP", "STG_DIAGNOSES"),
        ("HOSP", "STG_ICUSTAYS"),
        ("MARTS", "INT_SEPSIS_COHORT"),
        ("MARTS", "INT_TREATMENT_FLAGS"),
        ("MARTS", "MART_ANALYSIS_COHORT"),
    ]

    all_good = True
    for schema, table in expected_tables:
        try:
            cursor.execute(f"SELECT COUNT(*) FROM MIMIC_IV.{schema}.{table}")
            row_count = cursor.fetchone()[0]
            print(f"  ✓ {schema}.{table}: {row_count:,} rows")
        except Exception as e:
            print(f"  ✗ {schema}.{table}: NOT FOUND — {e}")
            all_good = False

    cursor.close()
    conn.close()

    return all_good


# ── main ──────────────────────────────────────────────────────────────────────


def main():
    print("=" * 60)
    print("mimic-rwe dbt setup")
    print("=" * 60)

    # step 1: snowflake schemas
    setup_marts_schema()

    # step 2: debug connection first
    if not run_dbt(["debug"]):
        print("\n✗ dbt debug failed — fix connection before continuing")
        print("  Common fixes:")
        print("  - Check SNOWFLAKE_ACCOUNT format: orgname-accountname")
        print("  - Make sure you ran: set -a && source .env && set +a")
        print("  - Verify warehouse is running in Snowflake UI")
        return

    # step 3: install dbt packages (if any)
    run_dbt(["deps"])

    # step 4: run models in dependency order
    steps = [
        (["run", "--select", "staging.*"], "staging models"),
        (["run", "--select", "int_sepsis_cohort"], "sepsis cohort"),
        (["run", "--select", "int_treatment_flags"], "treatment flags"),
        (["run", "--select", "mart_analysis_cohort"], "analysis mart"),
    ]

    for command, description in steps:
        print(f"\n── {description} ──")
        if not run_dbt(command):
            print(f"\n✗ Stopped at: {description}")
            print("  Fix the error above before continuing")
            return

    # step 5: run tests
    print("\n── running tests ──")
    run_dbt(["test"])

    # step 6: verify
    print("\n── verifying tables ──")
    if verify_tables():
        print("\n✓ Setup complete — ready for notebooks")
    else:
        print("\n⚠ Some tables missing — check dbt logs above")


if __name__ == "__main__":
    main()
