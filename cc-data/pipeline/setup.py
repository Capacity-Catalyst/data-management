"""One command to build the whole database from the workbook.

    uv run pipeline/setup.py path/to/workbook.xlsx

Steps:
  1. db/001_schema.sql            create relational tables (if missing)
  2. db/002_seed.sql              reference data (programs, roles, forms)
  3. load_raw.py                  every workbook tab -> raw.* (rebuilt each run)
  4. db/010_transform.sql         raw.* -> relational tables (never overwrites edits)
  5. db/003_public_flags.sql      what may appear on the public website
  6. db/020_reporting_views.sql   chart-ready views in reporting.*
  7. db/030_site_views.sql        public website views (reporting.site_*)

Safe to rerun. Each step runs in its own transaction, so a failure leaves the
database as it was before that step.
"""

import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).parent))
import load_raw  # noqa: E402

DB_DIR = Path(__file__).resolve().parent.parent / "db"

SUMMARY_TABLES = [
    "terms", "partners", "sectors", "partner_engagements", "cohort_facts",
    "cohort_demographic_counts", "alumni_panel_counts", "vendor_payments",
    "survey_questions", "survey_responses", "survey_answers",
]


def run_sql(conn, filename: str) -> None:
    print(f"- {filename}")
    with conn.transaction():
        conn.execute((DB_DIR / filename).read_text())


def main(workbook: str) -> None:
    load_dotenv()
    with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
        conn.add_notice_handler(lambda _: None)  # hide "already exists, skipping" noise

        run_sql(conn, "001_schema.sql")
        run_sql(conn, "002_seed.sql")

        print("- loading workbook into raw.*")
        with conn.transaction():
            load_raw.load(conn, workbook)

        run_sql(conn, "010_transform.sql")
        run_sql(conn, "003_public_flags.sql")  # after partners exist
        run_sql(conn, "020_reporting_views.sql")
        run_sql(conn, "030_site_views.sql")

        print("\nRow counts:")
        for t in SUMMARY_TABLES:
            n = conn.execute(f"select count(*) from public.{t}").fetchone()[0]
            print(f"  {t:<28}{n:>6}")

        mismatches = conn.execute("select * from reporting.check_host_counts").fetchall()
        if mismatches:
            print("\nHost counts that differ from the workbook (please review):")
            for term, derived, reported in mismatches:
                print(f"  {term}: {derived} from Partners tab vs {reported} reported")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
