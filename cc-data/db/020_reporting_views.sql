-- Reporting views: clean, chart-ready data. Every number shown publicly comes from here.
-- Safe to rerun ("create or replace"). Charts (Evidence) only read from this schema.

create schema if not exists reporting;

-- ---------------------------------------------------------------------------
-- Partners
-- ---------------------------------------------------------------------------

create or replace view reporting.partner_history with (security_invoker = true) as
select p.id                                         as partner_id,
       p.name                                       as partner,
       p.location,
       string_agg(distinct s.name, ', ')            as sector,
       count(distinct e.term_id)                    as terms_engaged,
       min(t.label) filter (where t.sort_key = x.first_key) as first_term,
       min(t.label) filter (where t.sort_key = x.last_key)  as last_term,
       count(distinct e.term_id) > 1                as is_returning,
       string_agg(distinct pr.name, ', ')           as roles
from partners p
left join partner_engagements e on e.partner_id = p.id
left join terms t               on t.id = e.term_id
left join partner_roles pr      on pr.id = e.role_id
left join partner_sectors ps    on ps.partner_id = p.id
left join sectors s             on s.id = ps.sector_id
left join lateral (
    select min(t2.sort_key) as first_key, max(t2.sort_key) as last_key
    from partner_engagements e2 join terms t2 on t2.id = e2.term_id
    where e2.partner_id = p.id
) x on true
group by p.id, p.name, p.location;

create or replace view reporting.partners_by_sector with (security_invoker = true) as
select coalesce(s.name, 'Not specified') as sector, count(*) as partners
from partners p
left join partner_sectors ps on ps.partner_id = p.id
left join sectors s          on s.id = ps.sector_id
group by 1;

-- Host organizations per externship term, counted from engagements.
create or replace view reporting.hosts_by_term with (security_invoker = true) as
with host_terms as (
    select e.partner_id, t.id as term_id, t.label, t.year, t.sort_key,
           min(t.sort_key) over (partition by e.partner_id) as first_key
    from partner_engagements e
    join terms t          on t.id = e.term_id
    join partner_roles pr on pr.id = e.role_id and pr.name = 'Extern Host'
)
select h.label as term, h.year, h.sort_key,
       count(*)                                     as hosts,
       count(*) filter (where h.sort_key = h.first_key) as new_hosts,
       count(*) filter (where h.sort_key > h.first_key) as returning_hosts,
       pgm.count                                    as pgm_led_hosts_reported
from host_terms h
left join participant_roles r on r.code = 'extern_host'
left join cohort_facts cf     on cf.term_id = h.term_id and cf.participant_role_id = r.id
left join cohort_demographic_counts pgm
       on pgm.cohort_fact_id = cf.id and pgm.category = 'pgm' and pgm.value = 'yes'
group by h.label, h.year, h.sort_key, pgm.count;

-- Data check: host counts from engagements vs. what the workbook reported.
create or replace view reporting.check_host_counts with (security_invoker = true) as
select t.label as term, h.hosts as hosts_from_engagements, cf.headcount as hosts_reported
from terms t
join programs p               on p.id = t.program_id and p.code = 'externship'
join participant_roles r      on r.code = 'extern_host'
left join cohort_facts cf     on cf.term_id = t.id and cf.participant_role_id = r.id
left join reporting.hosts_by_term h on h.term = t.label
where coalesce(h.hosts, -1) <> coalesce(cf.headcount, -1)
order by t.sort_key;

-- ---------------------------------------------------------------------------
-- Program activity
-- ---------------------------------------------------------------------------

create or replace view reporting.externship_by_term with (security_invoker = true) as
select t.label as term, t.year, t.sort_key, t.is_pilot,
       cf.headcount                              as externs,
       cf.weeks, cf.part_time_count, cf.full_time_count,
       cf.stipends_paid, cf.cc_contributed,
       cf.data_hours, cf.pd_hours,
       coalesce(cf.data_hours, 0) + coalesce(cf.pd_hours, 0) as total_hours
from cohort_facts cf
join participant_roles r on r.id = cf.participant_role_id and r.code = 'extern'
join terms t             on t.id = cf.term_id;

create or replace view reporting.cerc_by_term with (security_invoker = true) as
select t.label as term, t.year, t.sort_key, t.university,
       r.name as participant_group,
       cf.headcount, cf.stipends_paid, cf.data_hours, cf.pd_hours,
       coalesce(cf.data_hours, 0) + coalesce(cf.pd_hours, 0) as total_hours
from cohort_facts cf
join participant_roles r on r.id = cf.participant_role_id
join programs p          on p.id = r.program_id and p.code = 'cerc'
join terms t             on t.id = cf.term_id;

create or replace view reporting.hours_by_year with (security_invoker = true) as
select t.year, p.name as program,
       sum(cf.data_hours) as data_hours,
       sum(cf.pd_hours)   as pd_hours,
       coalesce(sum(cf.data_hours), 0) + coalesce(sum(cf.pd_hours), 0) as total_hours
from cohort_facts cf
join terms t    on t.id = cf.term_id
join programs p on p.id = t.program_id
where cf.data_hours is not null or cf.pd_hours is not null
group by t.year, p.name;

create or replace view reporting.stipends_by_year with (security_invoker = true) as
select t.year, p.name as program, sum(cf.stipends_paid) as stipends_paid
from cohort_facts cf
join terms t    on t.id = cf.term_id
join programs p on p.id = t.program_id
where cf.stipends_paid is not null
group by t.year, p.name;

create or replace view reporting.mentors_by_term with (security_invoker = true) as
select t.label as term, t.year, t.sort_key, cf.headcount as mentors,
       max(d.count) filter (where d.category = 'pgm') as pgm_mentors
from cohort_facts cf
join participant_roles r on r.id = cf.participant_role_id and r.code = 'extern_mentor'
join terms t             on t.id = cf.term_id
left join cohort_demographic_counts d on d.cohort_fact_id = cf.id
group by t.label, t.year, t.sort_key, cf.headcount;

create or replace view reporting.alumni_panels with (security_invoker = true) as
select cohort_year, panel_year, panelists from alumni_panel_counts;

-- ---------------------------------------------------------------------------
-- Demographics
-- ---------------------------------------------------------------------------

-- CERC: recorded aggregate counts
create or replace view reporting.cerc_demographics with (security_invoker = true) as
select t.label as term, t.year, t.sort_key, r.name as participant_group,
       d.category, d.value, d.count, d.is_lower_bound
from cohort_demographic_counts d
join cohort_facts cf     on cf.id = d.cohort_fact_id
join participant_roles r on r.id = cf.participant_role_id
join programs p          on p.id = r.program_id and p.code = 'cerc'
join terms t             on t.id = cf.term_id;

-- Externs: counted from survey answers, with consistent labels.
-- People can pick several options, so counts per option can exceed respondents.
create or replace view reporting.extern_demographics with (security_invoker = true) as
select q.code as category,
       t.label as term, t.year, t.sort_key,
       case
           when a.value_text ilike 'nonbinary%'        then 'Nonbinary'
           when a.value_text ilike 'prefer to self%'   then 'Self-described'
           when a.value_text ilike 'hispanic%'         then 'Hispanic or Latino/a/e/x'
           else a.value_text
       end as value,
       count(distinct a.response_id) as respondents
from survey_answers a
join survey_questions q  on q.id = a.question_id
                        and q.code in ('ethnicity', 'gender', 'other_underrepresented')
join survey_responses sr on sr.id = a.response_id
left join terms t        on t.id = sr.term_id
group by 1, 2, 3, 4, 5;

create or replace view reporting.extern_locations with (security_invoker = true) as
with v as (
    select sr.term_id, trim(a.value_text) as raw
    from survey_answers a
    join survey_questions q  on q.id = a.question_id and q.code = 'location'
    join survey_responses sr on sr.id = a.response_id
)
select initcap(trim(regexp_replace(raw,
           '[,\s]+(TX|Texas|CA|California|WA|Washington|NY|New York)$', '', 'i'))) as city,
       case
           when raw ~* '(TX|Texas)$'          then 'TX'
           when raw ~* '(CA|California)$'     then 'CA'
           when raw ~* '(WA|Washington)$'     then 'WA'
           when raw ~* '(NY|New York)$'       then 'NY'
       end as state,
       count(*) as externs
from v
group by 1, 2;

-- ---------------------------------------------------------------------------
-- Feedback
-- ---------------------------------------------------------------------------

create or replace view reporting.feedback_likert with (security_invoker = true) as
select q.code as question,
       substring(q.question_text from '\[(.+)\]') as statement,
       a.value_text as response,
       a.value_num  as score,
       count(*)     as responses
from survey_answers a
join survey_questions q on q.id = a.question_id and q.question_type = 'likert'
group by q.code, q.question_text, a.value_text, a.value_num;

create or replace view reporting.feedback_ratings with (security_invoker = true) as
select q.code as question, q.question_text,
       count(*)                        as responses,
       round(avg(a.value_num), 2)      as average,
       min(a.value_num)                as min,
       max(a.value_num)                as max
from survey_answers a
join survey_questions q on q.id = a.question_id and q.question_type = 'number'
group by q.code, q.question_text;

create or replace view reporting.feedback_program_elements with (security_invoker = true) as
select q.code as question, a.value_text as element, count(*) as responses
from survey_answers a
join survey_questions q on q.id = a.question_id
                       and q.code in ('keep_next_time', 'change_next_time')
group by q.code, a.value_text;
