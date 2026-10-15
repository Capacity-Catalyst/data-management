"""Load every tab of the Capacity Catalyst workbook into the `raw` schema.

Each tab becomes one table in `raw`, all columns stored as text, no cleaning.
Long survey headers are shortened to readable snake_case column names, and the
original header text is kept in `raw._columns` so nothing is lost.

`raw` is staging only: it is dropped and rebuilt on every run.

Usage:
    uv run pipeline/load_raw.py path/to/workbook.xlsx
"""

import datetime as dt
import re
import sys

import openpyxl
import psycopg

# Tabs that have no header row: give their columns names here.
HEADERLESS_TABS = {
    "PGM honoraria, fees": ["payee", "amount"],
}

# Readable names for long survey headers, matched by the start of the header.
HEADER_ALIASES = [
    ("timestamp", "submitted_at"),
    ("which capacity catalyst externship cohort", "cohort"),
    ("which of the following ethnicities", "ethnicity"),
    ("self-described ethnicity", "ethnicity_self_described"),
    ("which of the following genders", "gender"),
    ("self-described gender", "gender_self_described"),
    ("where did you live", "location"),
    ("do you (or did you ever) identify", "other_underrepresented"),
    ("what stands out", "stands_out"),
    ("what would you definitely keep", "keep_next_time"),
    ("what would you definitely change", "change_next_time"),
    ("explain your selections", "keep_change_explanation"),
    ("how would you rate the time", "rating_time"),
    ("how would you rate the stipend", "rating_stipend"),
    ("how likely are you to recommend", "likely_to_recommend"),
    ("is there anything else", "anything_else"),
    ("may we share", "may_share_publicly"),
    ('if you answered "yes" above', "attribution"),
    ("were you interested in continuing", "interest_continuing"),
    ("how, if at all, were you able", "acted_on_interest"),
    ("preferred name", "preferred_name"),
]

# "Indicate the extent ... [I felt adequately supported by my mentor]"
GRID_ALIASES = {
    "i got what i expected": "agree_got_expected",
    "i gained unexpected benefits": "agree_unexpected_benefits",
    "i felt adequately supported by my host": "agree_host_support",
    "i felt adequately supported by my mentor": "agree_mentor_support",
    "i felt supported in my own social/racial justice": "agree_justice_journey_support",
    "i contributed to the racial justice work": "agree_contributed_to_host",
    "the cohort experiences": "agree_cohort_experiences_valuable",
    "this externship experience was not": "agree_not_good_use_of_time",
}


def slug(text: str, max_len: int = 50) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", str(text).strip().lower()).strip("_")
    if not s:
        return ""
    if s[0].isdigit():
        s = "y_" + s.replace("_0", "")  # 2022.0 -> y_2022
    return s[:max_len].rstrip("_")


def column_name(header) -> str:
    if header is None:
        return ""
    h = str(header).strip()
    low = h.lower()
    grid = re.search(r"\[(.+)\]", h)
    if low.startswith("indicate the extent") and grid:
        inner = grid.group(1).lower()
        for prefix, name in GRID_ALIASES.items():
            if inner.startswith(prefix):
                return name
        return "agree_" + slug(inner, 40)
    for prefix, name in HEADER_ALIASES:
        if low.startswith(prefix):
            return name
    return slug(h)


def as_text(v):
    if v is None:
        return None
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (dt.datetime, dt.date)):
        return v.isoformat(sep=" ") if isinstance(v, dt.datetime) else v.isoformat()
    s = str(v)
    return s if s.strip() else None


def read_tab(ws):
    rows = [list(r) for r in ws.iter_rows(values_only=True)]
    rows = [r for r in rows if any(as_text(c) is not None for c in r)]
    if not rows:
        return [], [], []

    width = max(len(r) for r in rows)
    rows = [r + [None] * (width - len(r)) for r in rows]

    if ws.title in HEADERLESS_TABS:
        headers = HEADERLESS_TABS[ws.title]
        headers = headers + [None] * (width - len(headers))
        body = rows
    else:
        headers, body = rows[0], rows[1:]

    names, seen = [], set()
    for i, h in enumerate(headers):
        name = column_name(h) or f"col_{i + 1}"
        base, n = name, 2
        while name in seen:
            name, n = f"{base}_{n}", n + 1
        seen.add(name)
        names.append(name)

    # Drop columns that are empty in every row and have no header.
    keep = [
        i for i in range(width)
        if headers[i] is not None or any(as_text(r[i]) is not None for r in body)
    ]
    names = [names[i] for i in keep]
    originals = [as_text(headers[i]) for i in keep]
    body = [[as_text(r[i]) for i in keep] for r in body]
    return names, originals, body


def load(conn, workbook_path: str) -> None:
    wb = openpyxl.load_workbook(workbook_path, data_only=True, read_only=True)

    conn.execute("drop schema if exists raw cascade")
    conn.execute("create schema raw")
    conn.execute(
        """
        create table raw._columns (
            table_name text not null,
            column_name text not null,
            position int not null,
            original_header text,
            primary key (table_name, column_name)
        )
        """
    )

    for ws in wb.worksheets:
        table = slug(ws.title)
        names, originals, body = read_tab(ws)
        if not names:
            print(f"  skipped empty tab: {ws.title}")
            continue

        cols = ", ".join(f'"{n}" text' for n in names)
        conn.execute(f'create table raw."{table}" (_row int primary key, {cols})')
        conn.execute(f'alter table raw."{table}" enable row level security')

        col_list = ", ".join(f'"{n}"' for n in ["_row", *names])
        with conn.cursor() as cur:
            with cur.copy(f'copy raw."{table}" ({col_list}) from stdin') as copy:
                for i, row in enumerate(body, start=1):
                    copy.write_row([i, *row])
            cur.executemany(
                "insert into raw._columns values (%s, %s, %s, %s)",
                [(table, n, p, o) for p, (n, o) in enumerate(zip(names, originals), 1)],
            )
        print(f"  raw.{table}: {len(body)} rows, {len(names)} columns")

    conn.execute("alter table raw._columns enable row level security")


if __name__ == "__main__":
    import os

    from dotenv import load_dotenv

    load_dotenv()
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        load(conn, sys.argv[1])
    print("Done.")
