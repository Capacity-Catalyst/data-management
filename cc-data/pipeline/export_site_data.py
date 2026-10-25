"""Export every reporting.site_* view to site/data/<name>.json for the public website.

    uv run pipeline/export_site_data.py

Only views named site_* are exported, so nothing else in the database can leak
onto the public site by accident. Run by the GitHub Action before each deploy.
"""

import datetime as dt
import decimal
import json
import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row

OUT_DIR = Path(__file__).resolve().parent.parent / "site" / "data"


def to_json(v):
    if isinstance(v, decimal.Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    if isinstance(v, (dt.date, dt.datetime)):
        return v.isoformat()
    raise TypeError(f"Cannot serialize {type(v)}")


def main() -> None:
    load_dotenv()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for old in OUT_DIR.glob("*.json"):
        old.unlink()

    with psycopg.connect(os.environ["DATABASE_URL"], row_factory=dict_row) as conn:
        views = [
            r["table_name"]
            for r in conn.execute(
                """
                select table_name from information_schema.views
                where table_schema = 'reporting' and table_name like 'site\\_%'
                order by table_name
                """
            )
        ]
        for view in views:
            rows = conn.execute(f'select * from reporting."{view}"').fetchall()
            name = view.removeprefix("site_")
            (OUT_DIR / f"{name}.json").write_text(json.dumps(rows, default=to_json, indent=1))
            print(f"  {name}.json: {len(rows)} rows")

    meta = {"updated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="minutes")}
    (OUT_DIR / "meta.json").write_text(json.dumps(meta))

    # The page reads this list to know which files to load.
    names = sorted(p.stem for p in OUT_DIR.glob("*.json") if p.stem != "manifest")
    (OUT_DIR / "manifest.json").write_text(json.dumps(names))


if __name__ == "__main__":
    main()
