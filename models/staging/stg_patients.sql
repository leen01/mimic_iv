with source as (
    select * from {{ source('hosp', 'patients') }}
),

renamed as (
    select
        subject_id,
        gender,
        anchor_age                                    as age_at_anchor,
        anchor_year                                   as anchor_year,
        anchor_year_group,

        -- MIMIC-IV uses shifted dates; anchor_age is age at anchor_year
        -- We'll use this later to calculate age at admission
        dod                                           as date_of_death,
        case when dod is not null then 1 else 0 end   as died_in_hospital

    from source
)

select * from renamed