-- Views published to the PUBLIC website (reporting.site_*).
--
-- Every view in this file is exported to JSON and is world-readable once deployed.
-- Rules:
--   * aggregates only, never row-level survey data or free text
--   * demographic groups smaller than 3 are folded together so no one is identifiable
--   * partners with show_publicly = false are excluded by name
-- To add a chart: add a site_* view here, then a chart in site/charts.js.

-- Headline numbers ------------------------------------------------------------
create or replace view reporting.site_kpis with (security_invoker = true) as
select
    (select sum(cf.headcount) from cohort_facts cf
       join participant_roles r on r.id = cf.participant_role_id and r.code = 'extern')
        as extern_placements,
    (select count(distinct e.partner_id) from partner_engagements e
       join partner_roles pr on pr.id = e.role_id and pr.name = 'Extern Host')
        as host_organizations,
    (select count(*) from partners)
        as community_partners,
    (select sum(cf.headcount) from cohort_facts cf
       join participant_roles r on r.id = cf.participant_role_id and r.code = 'cerc_undergrad')
        as cerc_undergrad_placements,
    (select sum(stipends_paid) from cohort_facts)
        as stipends_paid,
    (select sum(coalesce(data_hours, 0) + coalesce(pd_hours, 0)) from cohort_facts)
        as support_hours,
    (select count(*) from terms)
        as cohorts;

-- Externship ------------------------------------------------------------------
create or replace view reporting.site_hosts_by_term with (security_invoker = true) as
select term, sort_key, 'New' as status, new_hosts as hosts from reporting.hosts_by_term
union all
select term, sort_key, 'Returning', returning_hosts from reporting.hosts_by_term;

create or replace view reporting.site_externs_by_term with (security_invoker = true) as
select term, sort_key, externs, is_pilot
from reporting.externship_by_term
where externs is not null;

-- Program totals by year --------------------------------------------------------
create or replace view reporting.site_hours_by_year with (security_invoker = true) as
select year, program, data_hours, pd_hours, total_hours
from reporting.hours_by_year;

create or replace view reporting.site_stipends_by_year with (security_invoker = true) as
select year, program, stipends_paid
from reporting.stipends_by_year
where stipends_paid > 0;

-- CERC --------------------------------------------------------------------------
create or replace view reporting.site_cerc_by_term with (security_invoker = true) as
select term, sort_key, university, participant_group, headcount
from reporting.cerc_by_term
where headcount is not null and headcount > 0;

-- Partners ----------------------------------------------------------------------
create or replace view reporting.site_partner_timeline with (security_invoker = true) as
select p.name as partner, t.label as term, t.sort_key, pg.name as program, pr.name as role
from partner_engagements e
join partners p       on p.id = e.partner_id and p.show_publicly
join terms t          on t.id = e.term_id
join programs pg      on pg.id = t.program_id
join partner_roles pr on pr.id = e.role_id;

create or replace view reporting.site_partners_by_sector with (security_invoker = true) as
select sector, partners from reporting.partners_by_sector;

-- Demographics (folded so no group is smaller than 3) ---------------------------
create or replace view reporting.site_extern_demographics with (security_invoker = true) as
with totals as (
    select category, sum(respondents) as n, value
    from reporting.extern_demographics
    where category in ('ethnicity', 'gender')
    group by category, value
),
folded as (
    select category,
           case when n < 3 then
                case category when 'ethnicity' then 'Another identity'
                              else 'Another gender identity' end
                else value end as value,
           sum(n) as respondents
    from totals
    group by 1, 2
),
respondents as (
    select q.code as category, count(distinct a.response_id) as total
    from survey_answers a
    join survey_questions q on q.id = a.question_id and q.code in ('ethnicity', 'gender')
    group by q.code
)
select f.category, f.value, f.respondents,
       round(f.respondents::numeric / r.total, 3) as share,
       r.total as total_respondents
from folded f
join respondents r using (category);

create or replace view reporting.site_cerc_demographics with (security_invoker = true) as
with totals as (
    select category, value, sum(count) as n
    from reporting.cerc_demographics
    where participant_group = 'Undergraduate' and category in ('ethnicity', 'gender')
    group by category, value
    having sum(count) > 0
),
folded as (
    select category,
           case when n < 3 then 'Another identity' else value end as value,
           sum(n) as students
    from totals group by 1, 2
)
select category, value, students,
       round(students::numeric / sum(students) over (partition by category), 3) as share
from folded;

-- Feedback ----------------------------------------------------------------------
-- "This externship was NOT a good use of my time" is reverse-scored and reworded so
-- every bar reads the same way (agree = positive). The chart footnote says so.
create or replace view reporting.site_feedback_likert with (security_invoker = true) as
select case when negative
            then 'This externship experience was a good use of my time'
            else statement end                       as statement,
       (array['Strongly disagree', 'Disagree', 'Neither agree nor disagree', 'Agree', 'Strongly agree'])
           [case when negative then 6 - score else score end::int] as response,
       case when negative then 6 - score else score end as score,
       responses,
       negative                                        as negatively_worded
from (
    select *, question = 'agree_not_good_use_of_time' as negative
    from reporting.feedback_likert
    where score is not null          -- drops "N/A or prefer not to respond"
) f;

create or replace view reporting.site_feedback_ratings with (security_invoker = true) as
select question,
       case question
           when 'likely_to_recommend' then 'Likely to recommend (0-10)'
           when 'rating_time'         then 'Time commitment rating'
           when 'rating_stipend'      then 'Stipend rating'
       end as label,
       case question when 'likely_to_recommend' then 10 end as scale_max,  -- other scales unconfirmed
       average, responses
from reporting.feedback_ratings;
