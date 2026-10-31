-- Transform raw.* (flat copies of the workbook tabs) into the relational tables.
--
-- Safe to rerun: every insert is "on conflict do nothing", so rows your manager
-- edited or added in Supabase are never overwritten.
--
-- Tabs NOT transformed on purpose:
--   charts, annual_cc_demographics  -> derived numbers, rebuilt as reporting views
--   board_demographics              -> identified people; needs a decision first

create schema if not exists etl;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- '1,500' -> 1500, '?' / 'N/A' / '' -> null
create or replace function etl.to_num(v text) returns numeric
language sql immutable as $$
    select case when v ~ '^\s*-?[0-9,]*\.?[0-9]+\s*$'
                then replace(trim(v), ',', '')::numeric end
$$;

-- 'Summer 20', 'Fall 21 TX State', 'Spring19 externship pilot', 'Fall 2019' -> one term.
-- default_program is used when the token does not say (plain 'Fall 22' in Partners = CERC).
create or replace function etl.parse_term(token text, default_program text)
returns table (season text, year int, program_code text, is_pilot boolean, university text)
language sql immutable as $$
    select initcap(g[1]),
           case when length(g[2]) = 2 then 2000 + g[2]::int else g[2]::int end,
           case when lower(g[1]) = 'summer' or g[3] ~* 'externship' then 'externship'
                when g[3] ~* 'course|tx state'                      then 'cerc'
                else default_program end,
           coalesce(g[3] ~* 'pilot', false),
           case when g[3] ~* 'tx state' then 'TX State' end
    from (select regexp_match(trim(token), '^(spring|summer|fall)\s*(\d{4}|\d{2})\s*(.*)$', 'i') as g) m
    where g is not null
$$;

create or replace function etl.cerc_role(role text) returns text
language sql immutable as $$
    select case lower(trim(role))
        when 'undergrad'    then 'cerc_undergrad'
        when 'np mentor'    then 'cerc_np_mentor'
        when 'developer'    then 'cerc_developer'
        when 'grad student' then 'cerc_grad_student'
    end   -- 'Undergrad + Mentor' rows are sums of other rows, so they map to null and are skipped
$$;

create or replace function etl.term_id(program text, token text) returns bigint
language sql stable as $$
    select t.id
    from etl.parse_term(token, program) p
    join programs pr on pr.code = p.program_code
    join terms t on t.program_id = pr.id and t.season = p.season and t.year = p.year
$$;

-- ---------------------------------------------------------------------------
-- Terms (collected from every tab that mentions one)
-- ---------------------------------------------------------------------------

with tokens(token, default_program) as (
    select trim(e), 'cerc' from raw.partners, unnest(string_to_array(engagements, ',')) e
    union all select year,     'externship' from raw.host_demographics
    union all select year,     'externship' from raw.mentor_demographics
    union all select semester, 'cerc'       from raw.cerc_demographics
    union all select cohort,   'externship' from raw.externs_feedback
    union all select cohort,   'externship' from raw.externs_ethnicity
    union all select cohort,   'externship' from raw.externs_gender
    union all select cohort,   'externship' from raw.externs_geography
    union all select cohort,   'externship' from raw.externs_other_underrepresented
)
insert into terms (program_id, season, year, is_pilot, university)
select pr.id, p.season, p.year, bool_or(p.is_pilot), max(p.university)
from tokens
cross join lateral etl.parse_term(token, default_program) p
join programs pr on pr.code = p.program_code
group by pr.id, p.season, p.year
on conflict (program_id, season, year) do nothing;

-- CERC university per semester ('HTU' or 'TX State')
update terms t
set university = case when trim(c.uni) ilike 'tx state' then 'TX State' else upper(trim(c.uni)) end
from raw.cerc_demographics c
where c.uni is not null
  and t.university is null
  and t.id = etl.term_id('cerc', c.semester);

-- ---------------------------------------------------------------------------
-- Partners, sectors, roles, engagements
-- ---------------------------------------------------------------------------

insert into sectors (name)
select distinct trim(sector_area_of_focus)
from raw.partners
where nullif(trim(sector_area_of_focus), '') is not null
on conflict (name) do nothing;

insert into partners (name, location, notes)
select trim(name), trim(city_st), nullif(trim(notes), '')
from raw.partners
where nullif(trim(name), '') is not null
on conflict (name) do nothing;

insert into partner_sectors (partner_id, sector_id)
select p.id, s.id
from raw.partners r
join partners p on p.name = trim(r.name)
join sectors  s on s.name = trim(r.sector_area_of_focus)
on conflict do nothing;

insert into partner_role_assignments (partner_id, role_id)
select p.id, pr.id
from raw.partners r
join partners p on p.name = trim(r.name)
cross join lateral unnest(string_to_array(r.role, ',')) x(role_name)
join partner_roles pr on pr.name = trim(x.role_name)
on conflict do nothing;

-- The workbook lists roles per partner, not per term, so the role for each
-- engagement is inferred: externship term -> Extern Host; CERC term -> the
-- partner's course role if it has one, otherwise Collaborator.
insert into partner_engagements (partner_id, term_id, role_id, notes)
select p.id, t.id, pr.id, 'Imported from workbook; role inferred from program'
from raw.partners r
join partners p on p.name = trim(r.name)
cross join lateral unnest(string_to_array(r.engagements, ',')) e(token)
cross join lateral etl.parse_term(e.token, 'cerc') pt
join programs prog on prog.code = pt.program_code
join terms t on t.program_id = prog.id and t.season = pt.season and t.year = pt.year
join partner_roles pr on pr.name = case
        when pt.program_code = 'externship'            then 'Extern Host'
        when r.role ilike '%course nonprofit partner%' then 'Course Nonprofit Partner'
        when r.role ilike '%collaborator%'             then 'Collaborator'
        else 'Course Nonprofit Partner' end
on conflict (partner_id, term_id, role_id) do nothing;

-- ---------------------------------------------------------------------------
-- Cohort facts
-- ---------------------------------------------------------------------------

-- Externs (Host demographics tab)
insert into cohort_facts (term_id, participant_role_id, headcount, weeks, part_time_count,
                          full_time_count, stipends_paid, cc_contributed, data_hours, pd_hours)
select etl.term_id('externship', h.year), r.id,
       etl.to_num(h.total_externs), etl.to_num(h.weeks), etl.to_num(h.pt), etl.to_num(h.ft),
       etl.to_num(h.total_stipends), etl.to_num(h.cc_contributed),
       etl.to_num(h.data_hours), etl.to_num(h.pd_hours)
from raw.host_demographics h
join participant_roles r on r.code = 'extern'
where etl.term_id('externship', h.year) is not null
on conflict (term_id, participant_role_id) do nothing;

-- Host organizations: reported count kept for history; compare with
-- reporting.check_host_counts, which counts them from partner_engagements.
insert into cohort_facts (term_id, participant_role_id, headcount, notes)
select etl.term_id('externship', h.year), r.id, etl.to_num(h.total_hosts),
       'Headcount as reported in workbook'
from raw.host_demographics h
join participant_roles r on r.code = 'extern_host'
where etl.term_id('externship', h.year) is not null
on conflict (term_id, participant_role_id) do nothing;

insert into cohort_demographic_counts (cohort_fact_id, category, value, count)
select cf.id, 'pgm', 'yes', etl.to_num(h.pgm_led)
from raw.host_demographics h
join participant_roles r on r.code = 'extern_host'
join cohort_facts cf on cf.participant_role_id = r.id
                    and cf.term_id = etl.term_id('externship', h.year)
where etl.to_num(h.pgm_led) is not null
on conflict do nothing;

-- Externship mentors
insert into cohort_facts (term_id, participant_role_id, headcount, notes)
select etl.term_id('externship', m.year), r.id, etl.to_num(m.total),
       nullif('Duplicates: ' || coalesce(m.duplicates, ''), 'Duplicates: ')
from raw.mentor_demographics m
join participant_roles r on r.code = 'extern_mentor'
where etl.term_id('externship', m.year) is not null
on conflict (term_id, participant_role_id) do nothing;

insert into cohort_demographic_counts (cohort_fact_id, category, value, count)
select cf.id, v.category, v.value, etl.to_num(v.raw_count)
from raw.mentor_demographics m
join participant_roles r on r.code = 'extern_mentor'
join cohort_facts cf on cf.participant_role_id = r.id
                    and cf.term_id = etl.term_id('externship', m.year)
cross join lateral (values
    ('pgm',    'yes',       m.pgm),
    ('gender', 'Male',      m.male),
    ('gender', 'Female',    m.female),
    ('gender', 'Nonbinary', m.nb)
) v(category, value, raw_count)
where etl.to_num(v.raw_count) is not null
on conflict do nothing;

-- CERC cohorts
insert into cohort_facts (term_id, participant_role_id, headcount, stipends_paid, data_hours, pd_hours)
select etl.term_id('cerc', c.semester), r.id,
       etl.to_num(c.total), etl.to_num(c.stipends), etl.to_num(c.data_hours), etl.to_num(c.pd_hours)
from raw.cerc_demographics c
join participant_roles r on r.code = etl.cerc_role(c.role)
where etl.term_id('cerc', c.semester) is not null
on conflict (term_id, participant_role_id) do nothing;

insert into cohort_demographic_counts (cohort_fact_id, category, value, count, is_lower_bound)
select cf.id, v.category, v.value,
       etl.to_num(replace(v.raw_count, '+', '')),
       v.raw_count like '%+'
from raw.cerc_demographics c
join participant_roles r on r.code = etl.cerc_role(c.role)
join cohort_facts cf on cf.participant_role_id = r.id
                    and cf.term_id = etl.term_id('cerc', c.semester)
cross join lateral (values
    ('ethnicity',    'White',       c.white),
    ('ethnicity',    'Hispanic',    c.hispanic),
    ('ethnicity',    'Black',       c.black),
    ('ethnicity',    'Asian',       c.asian),
    ('ethnicity',    'Multiracial', c.mixed),
    ('ethnicity',    'Other',       c.other),
    ('gender',       'Female',      c.female),
    ('gender',       'Male',        c.male),
    ('gender',       'Nonbinary',   c.nb),
    ('low_income',   'yes',         c.low_income),
    ('nih_underrep', 'yes',         c.nih_underrep)
) v(category, value, raw_count)
where etl.to_num(replace(v.raw_count, '+', '')) is not null
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Alumni panels (unpivot cohort x panel-year grid) and vendor payments
-- ---------------------------------------------------------------------------

insert into alumni_panel_counts (cohort_year, panel_year, panelists)
select etl.to_num(a.cohort), substring(kv.key from 3)::int, etl.to_num(kv.value)
from raw.externs_alumni_panels a
cross join lateral jsonb_each_text(to_jsonb(a) - '_row' - 'cohort') kv
where etl.to_num(a.cohort) is not null
  and etl.to_num(kv.value) is not null
on conflict (cohort_year, panel_year) do nothing;

insert into vendor_payments (payee, partner_id, amount)
select trim(v.payee), p.id, etl.to_num(v.amount)
from raw.pgm_honoraria_fees v
left join partners p on lower(p.name) = lower(trim(v.payee))
where nullif(trim(v.payee), '') is not null
on conflict (payee) do nothing;

-- ---------------------------------------------------------------------------
-- Surveys
-- ---------------------------------------------------------------------------

insert into survey_questions (form_id, code, position, question_text, question_type)
select f.id, c.column_name, c.position, c.original_header,
       case
           when c.column_name in ('ethnicity', 'gender', 'keep_next_time',
                                  'change_next_time', 'interest_continuing') then 'multi'
           when c.column_name like 'agree\_%'                                  then 'likert'
           when c.column_name in ('rating_time', 'rating_stipend',
                                  'likely_to_recommend')                       then 'number'
           when c.column_name in ('other_underrepresented',
                                  'may_share_publicly')                        then 'single'
           else 'text'
       end
from survey_forms f
join raw._columns c on c.table_name = f.code
where c.column_name not in ('submitted_at', 'cohort')
  and c.column_name not like 'col\_%'          -- scratch notes beside the form data
  and c.original_header is not null
on conflict (form_id, code) do nothing;

-- Gather every survey tab into one place as JSON so the next steps are generic.
drop table if exists survey_rows;
create temp table survey_rows (form_code text, data jsonb);

do $$
declare f text;
begin
    for f in select code from survey_forms loop
        if to_regclass(format('raw.%I', f)) is not null then
            execute format('insert into survey_rows select %L, to_jsonb(r) from raw.%I r', f, f);
        end if;
    end loop;
end $$;

-- Rows typed in by hand have text like "Saro's manual input" instead of a timestamp.
insert into survey_responses (form_id, term_id, submitted_at, source, import_key)
select f.id,
       etl.term_id('externship', s.data->>'cohort'),
       case when is_form then (s.data->>'submitted_at')::timestamp end,
       case when is_form then 'google_form' else 'manual' end,
       s.form_code || ':row' || (s.data->>'_row')
from survey_rows s
join survey_forms f on f.code = s.form_code
cross join lateral (select coalesce(s.data->>'submitted_at', '') ~ '^\d{4}-\d{2}-\d{2}' as is_form) x
on conflict (import_key) do nothing;

insert into survey_answers (response_id, question_id, value_text, value_num)
select sr.id, q.id, trim(o.opt),
       case q.question_type
           when 'number' then etl.to_num(o.opt)
           when 'likert' then case lower(trim(o.opt))
               when 'strongly disagree'          then 1
               when 'disagree'                   then 2
               when 'neither agree nor disagree' then 3
               when 'agree'                      then 4
               when 'strongly agree'             then 5
           end
       end
from survey_rows s
join survey_forms f     on f.code = s.form_code
join survey_responses sr on sr.import_key = s.form_code || ':row' || (s.data->>'_row')
join survey_questions q on q.form_id = f.id
cross join lateral unnest(
    case
        when s.data->>q.code is null then array[]::text[]
        when q.question_type <> 'multi' then array[s.data->>q.code]
        -- these options themselves contain commas ("Yes, I wanted to ...")
        when q.code = 'interest_continuing'
            then regexp_split_to_array(s.data->>q.code, ',\s*(?=Yes,|No\M)')
        else regexp_split_to_array(s.data->>q.code, ',\s*')
    end
) o(opt)
where trim(o.opt) <> ''
on conflict (response_id, question_id, value_text) do nothing;
