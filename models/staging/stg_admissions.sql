with source as (
    select * from {{ source('hosp', 'admissions') }}
),

renamed as (
    select
        subject_id,
        hadm_id,
        admittime                                               as admit_time,
        dischtime                                               as discharge_time,
        deathtime                                               as death_time,
        admission_type,
        admission_location,
        discharge_location,
        insurance,
        marital_status,
        race,
        hospital_expire_flag                                    as died_during_admission,

        -- length of stay in days
        datediff('hour', admittime, dischtime) / 24.0           as los_days,

        -- flag 28-day mortality (your primary outcome)
        case
            when deathtime is not null
            and datediff('day', admittime, deathtime) <= 28
            then 1 else 0
        end                                                     as mortality_28d

    from source
)

select * from renamed