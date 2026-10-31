-- Capacity Catalyst relational schema (public).
-- Safe to rerun: everything is "if not exists".
--
-- Conventions
--   * Every table has `id bigint generated always as identity` (except pure junction tables).
--   * Natural keys get UNIQUE constraints to block duplicates.
--   * Foreign keys are ON DELETE RESTRICT unless the child cannot exist without its parent.
--   * Only recorded facts are stored. Totals, "new hosts", percentages etc. live in reporting views.
--   * Row level security is on for every table. With no policies, the public API key
--     cannot read anything; the Supabase dashboard and direct DB connections still can.

-- ---------------------------------------------------------------------------
-- Reference / lookup tables
-- ---------------------------------------------------------------------------

create table if not exists programs (
    id          bigint generated always as identity primary key,
    code        text not null unique,          -- 'externship', 'cerc'
    name        text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists terms (
    id          bigint generated always as identity primary key,
    program_id  bigint not null references programs(id) on delete restrict,
    season      text not null check (season in ('Spring', 'Summer', 'Fall')),
    year        int  not null check (year between 2015 and 2100),
    university  text,                          -- CERC only, e.g. 'HTU', 'TX State'
    is_pilot    boolean not null default false,
    label       text generated always as (season || ' ' || year) stored,
    sort_key    int  generated always as (
                    year * 10 + case season when 'Spring' then 1 when 'Summer' then 2 else 3 end
                ) stored,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (program_id, season, year)
);

create table if not exists sectors (
    id          bigint generated always as identity primary key,
    name        text not null unique,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists partner_roles (
    id          bigint generated always as identity primary key,
    name        text not null unique,          -- 'Extern Host', 'Course Nonprofit Partner', 'Collaborator'
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists participant_roles (
    id          bigint generated always as identity primary key,
    program_id  bigint not null references programs(id) on delete restrict,
    code        text not null unique,          -- 'extern', 'extern_host', 'cerc_undergrad', ...
    name        text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Partners
-- ---------------------------------------------------------------------------

create table if not exists partners (
    id          bigint generated always as identity primary key,
    name        text not null unique,
    location    text,                          -- 'Austin, TX'; multiple separated by ';'
    pgm_led     boolean,                       -- unknown for historical partners
    notes       text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists partner_sectors (
    partner_id  bigint not null references partners(id) on delete cascade,
    sector_id   bigint not null references sectors(id)  on delete restrict,
    primary key (partner_id, sector_id)
);

-- Roles a partner has ever held (from the "Role" column).
create table if not exists partner_role_assignments (
    partner_id  bigint not null references partners(id)      on delete cascade,
    role_id     bigint not null references partner_roles(id) on delete restrict,
    primary key (partner_id, role_id)
);

-- One row per partner per term per role. "Has this org participated before?" is a query on this.
create table if not exists partner_engagements (
    id          bigint generated always as identity primary key,
    partner_id  bigint not null references partners(id)      on delete restrict,
    term_id     bigint not null references terms(id)         on delete restrict,
    role_id     bigint not null references partner_roles(id) on delete restrict,
    notes       text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (partner_id, term_id, role_id)
);

-- ---------------------------------------------------------------------------
-- Cohort facts (recorded numbers per term per participant group)
-- ---------------------------------------------------------------------------

create table if not exists cohort_facts (
    id                   bigint generated always as identity primary key,
    term_id              bigint not null references terms(id)             on delete restrict,
    participant_role_id  bigint not null references participant_roles(id) on delete restrict,
    headcount            int     check (headcount >= 0),
    weeks                int     check (weeks >= 0),
    part_time_count      int     check (part_time_count >= 0),
    full_time_count      int     check (full_time_count >= 0),
    stipends_paid        numeric(12, 2) check (stipends_paid >= 0),
    cc_contributed       numeric(12, 2) check (cc_contributed >= 0),
    data_hours           numeric(10, 2) check (data_hours >= 0),
    pd_hours             numeric(10, 2) check (pd_hours >= 0),
    notes                text,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),
    unique (term_id, participant_role_id)
);

-- Aggregate demographic counts recorded per cohort (CERC, mentors, host PGM-led counts).
create table if not exists cohort_demographic_counts (
    id              bigint generated always as identity primary key,
    cohort_fact_id  bigint not null references cohort_facts(id) on delete cascade,
    category        text not null check (category in ('ethnicity', 'gender', 'pgm', 'low_income', 'nih_underrep')),
    value           text not null,             -- 'Black', 'Female', 'yes', ...
    count           int  not null check (count >= 0),
    is_lower_bound  boolean not null default false,   -- recorded as '2+'
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    unique (cohort_fact_id, category, value)
);

create table if not exists alumni_panel_counts (
    id           bigint generated always as identity primary key,
    cohort_year  int not null,
    panel_year   int not null,
    panelists    int not null check (panelists >= 0),
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (cohort_year, panel_year)
);

create table if not exists vendor_payments (
    id          bigint generated always as identity primary key,
    payee       text not null unique,
    partner_id  bigint references partners(id) on delete restrict,
    amount      numeric(12, 2) check (amount >= 0),
    notes       text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Surveys (anonymous; one row per answer so new questions need no schema change)
-- ---------------------------------------------------------------------------

create table if not exists survey_forms (
    id          bigint generated always as identity primary key,
    code        text not null unique,
    name        text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table if not exists survey_questions (
    id             bigint generated always as identity primary key,
    form_id        bigint not null references survey_forms(id) on delete restrict,
    code           text not null,
    position       int  not null,
    question_text  text not null,
    question_type  text not null check (question_type in ('single', 'multi', 'likert', 'number', 'text')),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    unique (form_id, code)
);

create table if not exists survey_responses (
    id            bigint generated always as identity primary key,
    form_id       bigint not null references survey_forms(id) on delete restrict,
    term_id       bigint references terms(id) on delete restrict,
    submitted_at  timestamp,                   -- as recorded by Google Forms; null for manual entries
    source        text not null default 'manual' check (source in ('google_form', 'manual')),
    import_key    text unique,                 -- set by imports so reruns never duplicate; leave blank when adding by hand
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Multi-select questions get one row per selected option.
create table if not exists survey_answers (
    id           bigint generated always as identity primary key,
    response_id  bigint not null references survey_responses(id) on delete cascade,
    question_id  bigint not null references survey_questions(id) on delete restrict,
    value_text   text not null,
    value_num    numeric,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (response_id, question_id, value_text)
);

-- ---------------------------------------------------------------------------
-- Indexes on foreign keys (Postgres does not create these automatically)
-- ---------------------------------------------------------------------------

create index if not exists terms_program_idx               on terms (program_id);
create index if not exists participant_roles_program_idx   on participant_roles (program_id);
create index if not exists partner_sectors_sector_idx      on partner_sectors (sector_id);
create index if not exists partner_role_assign_role_idx    on partner_role_assignments (role_id);
create index if not exists engagements_term_idx            on partner_engagements (term_id);
create index if not exists engagements_role_idx            on partner_engagements (role_id);
create index if not exists cohort_facts_role_idx           on cohort_facts (participant_role_id);
create index if not exists vendor_payments_partner_idx     on vendor_payments (partner_id);
create index if not exists survey_questions_form_idx       on survey_questions (form_id);
create index if not exists survey_responses_term_idx       on survey_responses (term_id);
create index if not exists survey_answers_question_idx     on survey_answers (question_id);

-- ---------------------------------------------------------------------------
-- updated_at trigger + row level security on every table
-- ---------------------------------------------------------------------------

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end $$;

do $$
declare t text;
begin
    for t in
        select c.table_name
        from information_schema.columns c
        join information_schema.tables tb
          on tb.table_schema = c.table_schema and tb.table_name = c.table_name
        where c.table_schema = 'public' and c.column_name = 'updated_at'
          and tb.table_type = 'BASE TABLE'
    loop
        execute format('drop trigger if exists %I_updated_at on public.%I', t, t);
        execute format(
            'create trigger %I_updated_at before update on public.%I
             for each row execute function set_updated_at()', t, t);
    end loop;

    for t in select tablename from pg_tables where schemaname = 'public' loop
        execute format('alter table public.%I enable row level security', t);
    end loop;
end $$;
