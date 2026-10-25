-- Controls what can appear on the public website. Safe to rerun.

alter table partners
    add column if not exists show_publicly boolean not null default true;

comment on column partners.show_publicly is
    'Uncheck to hide this partner''s name from the public website charts.';

-- Partners marked confidential in the original workbook stay off the website.
update partners
set show_publicly = false
where name ilike '%confidential%' and show_publicly;
