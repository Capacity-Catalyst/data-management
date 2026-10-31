-- Reference data. Safe to rerun.

insert into programs (code, name) values
    ('externship', 'Externship'),
    ('cerc',       'CERC (course-based)')
on conflict (code) do nothing;

insert into partner_roles (name) values
    ('Extern Host'),
    ('Course Nonprofit Partner'),
    ('Collaborator')
on conflict (name) do nothing;

insert into participant_roles (program_id, code, name)
select p.id, v.code, v.name
from (values
    ('externship', 'extern',            'Extern'),
    ('externship', 'extern_host',       'Host organization'),
    ('externship', 'extern_mentor',     'Mentor'),
    ('cerc',       'cerc_undergrad',    'Undergraduate'),
    ('cerc',       'cerc_np_mentor',    'Nonprofit mentor'),
    ('cerc',       'cerc_developer',    'Developer'),
    ('cerc',       'cerc_grad_student', 'Grad student')
) as v(program, code, name)
join programs p on p.code = v.program
on conflict (code) do nothing;

insert into survey_forms (code, name) values
    ('externs_feedback',        'Externship feedback'),
    ('externs_ethnicity',       'Extern ethnicity'),
    ('externs_gender',          'Extern gender'),
    ('externs_geography',       'Extern location'),
    ('externs_other_underrepresented', 'Extern other underrepresented groups')
on conflict (code) do nothing;
