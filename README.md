# Capacity Catalyst data

Postgres (Supabase) database for Capacity Catalyst program data, plus the scripts that build it.

## How it fits together

```
workbook.xlsx ──load_raw.py──► raw.*        flat copies of each tab (staging, rebuilt every run)
                                  │
                       010_transform.sql
                                  ▼
                              public.*      relational tables, edited in Supabase
                                  │
                     020_reporting_views.sql
                                  ▼
                            reporting.*     chart-ready views (read by the charts site)
```

| Folder | What's in it |
|---|---|
| `db/001_schema.sql` | Tables, keys, constraints, row level security |
| `db/002_seed.sql` | Reference rows: programs, partner roles, participant groups, survey forms |
| `db/010_transform.sql` | Parses `raw.*` into the relational tables |
| `db/020_reporting_views.sql` | Views used for charts |
| `pipeline/load_raw.py` | Loads every workbook tab into `raw.*` |
| `pipeline/setup.py` | Runs all of the above in order |

## First-time setup

1. **Get the connection string.** Supabase dashboard → **Connect** → **Session pooler** (port 5432; works on IPv4 networks). Replace `[YOUR-PASSWORD]` with the database password.
2. **Create `.env`** in this folder (never commit it):
   ```
   DATABASE_URL=postgresql://postgres.xxxx:PASSWORD@aws-0-us-west-1.pooler.supabase.com:5432/postgres
   ```
3. **Install [uv](https://docs.astral.sh/uv/getting-started/installation/) and run:**
   ```bash
   uv sync
   uv run pipeline/setup.py "path/to/workbook.xlsx"
   ```
   `uv sync` creates `.venv` and installs the locked dependencies from `uv.lock`. To add a dependency, use `uv add <package>`.
   Download the workbook from Google Sheets with **File → Download → Microsoft Excel (.xlsx)**. Keep it out of the repo (it's in `.gitignore`), since it contains survey responses.

Rerunning `setup.py` is safe: it never overwrites or duplicates rows already in the relational tables.

## Tables

```
programs ──< terms ──< partner_engagements >── partners ──< partner_sectors >── sectors
   │           │                   │              └──< partner_role_assignments >── partner_roles
   │           │                   └── partner_roles
   │           ├──< cohort_facts ──< cohort_demographic_counts
   │           │        └── participant_roles
   │           └──< survey_responses ──< survey_answers >── survey_questions >── survey_forms
   └──< participant_roles
alumni_panel_counts     vendor_payments ── partners
```

| Table | One row per |
|---|---|
| `terms` | program term, e.g. Externship Summer 2024, CERC Fall 2023 (TX State) |
| `partners` | organization |
| `partner_engagements` | organization × term × role. Answers "has this org participated before?" |
| `cohort_facts` | term × participant group (externs, hosts, mentors, CERC undergrads, ...): headcount, stipends, hours |
| `cohort_demographic_counts` | recorded aggregate count, e.g. CERC Fall 2022 undergrads, Black = 8 |
| `survey_responses` / `survey_answers` | anonymous form response / one answer (multi-select answers get one row per option) |

### Rules of the schema

- Every table has an auto-generated `id`. Rename anything freely; links use ids, not names.
- Unique constraints block duplicates (e.g. the same partner twice in the same term and role).
- You can't delete a term, partner, or role that other rows still point to. Delete the dependent rows first.
- Only recorded facts are stored. Totals, "new hosts", percentages, and total hours are computed in `reporting.*`, so they never go stale.
- Row level security is on everywhere. The dashboard and direct connections work; the public API key can't read anything.

## Editing data (Supabase Table Editor)

| To do this | Do this |
|---|---|
| Add a new term | Insert into `terms` (program, season, year; university for CERC) |
| Add a new partner | Insert into `partners`, then `partner_sectors` |
| Record a partner in a term | Insert into `partner_engagements` (pick partner, term, role from the dropdowns) |
| Record cohort numbers | Insert into `cohort_facts` for that term and participant group |
| Add a new sector or role | Insert into `sectors` / `partner_roles` |

`created_at` and `updated_at` are filled in automatically.

## Data to review (from the first import)

- **Engagement roles were inferred.** The workbook lists roles per partner, not per term. Externship terms were set to *Extern Host*; CERC terms to *Course Nonprofit Partner* if the partner had that role, otherwise *Collaborator*. These rows have the note "role inferred from program".
- **Host counts that don't match** (`select * from reporting.check_host_counts`): Spring 2019 (2 in Partners tab vs 3 hosts) and Summer 2020 (5 in Partners vs 4 in hosts), Summer 2026 is not updated yet.
- **PGM-led** is only known as yearly totals, not per partner. `partners.pgm_led` is empty until filled in.
- **Board demographics** were not imported (named individuals with demographic data); they stay in `raw.board_demographics` pending a decision.
- **Skipped as derived:** Charts tab, Annual CC demographics, Totals/Maximum rows, "Undergrad + Mentor" rows, and side notes like "3 of 4" next to survey data.
- **Mentor "Duplicates"** column text is kept in `cohort_facts.notes`.
- **"HT"** in the honoraria tab wasn't matched to a partner. If it's Huston-Tillotson, set `vendor_payments.partner_id`.
- **Sector spelling:** "veterenary equity" was imported as-is.
