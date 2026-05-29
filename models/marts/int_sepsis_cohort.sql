/*
  Sepsis ICU cohort — study design
  ---------------------------------
  Population : Adult ICU patients with a sepsis diagnosis
  Index date : First ICU admission during the hospitalization
  Inclusion  : age >= 18, sepsis ICD code present, first ICU stay only
  Exclusion  : ICU LOS < 4 hours (likely transfers/errors),
               age > 89 (MIMIC censors these as 91),
               missing admission or discharge time
  Outcome    : 28-day mortality from ICU admission
*/

with patients as (
    select * from {{ ref('stg_patients') }}
),

admissions as (
    select * from {{ ref('stg_admissions') }}
),

diagnoses as (
    select * from {{ ref('stg_diagnoses') }}
),

icustays as (
    select * from {{ ref('stg_icustays') }}
    where icu_stay_seq = 1   -- first ICU stay per admission only
),

-- admissions that have at least one sepsis diagnosis code
sepsis_admissions as (
    select distinct hadm_id
    from diagnoses
    where is_sepsis_dx = 1
),

-- calculate age at admission using MIMIC anchor logic
patient_age as (
    select
        p.subject_id,
        p.gender,
        p.date_of_death,
        a.hadm_id,
        a.admit_time,
        a.discharge_time,
        a.death_time,
        a.los_days,
        a.died_during_admission,
        a.mortality_28d,
        a.insurance,
        a.marital_status,
        a.race,

        -- anchor_age is age at anchor_year; shift to admission year
        p.age_at_anchor + (
            year(try_to_timestamp(a.admit_time)) - p.anchor_year
        )                                               as age_at_admission

    from patients p
    inner join admissions a using (subject_id)
),

cohort as (
    select
        pa.subject_id,
        pa.hadm_id,
        i.stay_id,

        -- index date is ICU admission time
        i.icu_intime                                    as index_date,
        i.icu_outtime,
        i.icu_los_days,

        pa.age_at_admission,
        pa.gender,
        pa.race,
        pa.insurance,
        pa.marital_status,

        pa.los_days                                     as hospital_los_days,
        pa.died_during_admission,
        pa.mortality_28d,

        -- 28-day mortality from ICU admission (primary outcome)
        case
            when pa.death_time is not null
            and datediff('day', i.icu_intime, pa.death_time) <= 28
            then 1 else 0
        end                                             as outcome_mortality_28d,

        -- time-to-event for survival analysis (days from ICU admit)
        case
            when pa.death_time is not null
            then datediff('day', i.icu_intime, pa.death_time)
            else datediff('day', i.icu_intime, pa.discharge_time)
        end                                             as time_to_event_days,

        -- event indicator for KM / Cox (1 = died, 0 = censored)
        case when pa.death_time is not null then 1 else 0
        end                                             as event_observed

    from patient_age pa
    inner join icustays i using (hadm_id)
    inner join sepsis_admissions sa using (hadm_id)

    where
        pa.age_at_admission >= 18
        and pa.age_at_admission <= 89
        and i.icu_los_days >= (4.0 / 24.0)             -- exclude stays < 4 hours
        and pa.admit_time is not null
        and pa.discharge_time is not null
)

select * from cohort