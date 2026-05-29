/*
  Final analysis-ready wide table
  --------------------------------
  One row per ICU stay. Joins cohort + treatment + covariates.
  This is the table Python pulls directly for PSM and survival analysis.
*/

with cohort as (
    select * from {{ ref('int_sepsis_cohort') }}
),

treatment as (
    select * from {{ ref('int_treatment_flags') }}
),

-- pull key lab values at ICU admission as covariates
-- first value within 6h of ICU admit per lab item
labs as (
    select
        ie.stay_id,
        le.itemid,
        le.valuenum,
        row_number() over (
            partition by ie.stay_id, le.itemid
            order by le.charttime asc
        ) as rn

    from {{ source('icu', 'icustays') }} ie
    inner join {{ source('hosp', 'labevents') }} le
        on ie.hadm_id = le.hadm_id
    inner join {{ ref('int_sepsis_cohort') }} c
        on ie.stay_id = c.stay_id

    where
        le.charttime >= c.index_date
        and le.charttime < dateadd('hour', 6, c.index_date)
        and le.itemid in (
            51006,   -- BUN
            50912,   -- creatinine
            50885,   -- bilirubin
            51265,   -- platelet count
            51301,   -- WBC
            50813,   -- lactate
            50882    -- bicarbonate
        )
        and le.valuenum is not null
        and le.valuenum > 0
),

lab_pivoted as (
    select
        stay_id,
        max(case when itemid = 51006  and rn = 1 then valuenum end) as bun,
        max(case when itemid = 50912  and rn = 1 then valuenum end) as creatinine,
        max(case when itemid = 50885  and rn = 1 then valuenum end) as bilirubin,
        max(case when itemid = 51265  and rn = 1 then valuenum end) as platelets,
        max(case when itemid = 51301  and rn = 1 then valuenum end) as wbc,
        max(case when itemid = 50813  and rn = 1 then valuenum end) as lactate,
        max(case when itemid = 50882  and rn = 1 then valuenum end) as bicarbonate
    from labs
    group by stay_id
),

final as (
    select
        -- identifiers
        c.subject_id,
        c.hadm_id,
        c.stay_id,
        c.index_date,

        -- treatment
        t.treatment_group,      -- 1 = vasopressor, 0 = fluid only
        t.treatment_label,
        t.total_fluid_ml,
        t.vasopressor_count,

        -- outcome
        c.outcome_mortality_28d,
        c.time_to_event_days,
        c.event_observed,        -- 1 = died, 0 = censored

        -- baseline covariates for PSM
        c.age_at_admission,
        c.gender,
        c.race,
        c.insurance,
        c.icu_los_days,
        c.hospital_los_days,

        -- lab covariates
        lp.bun,
        lp.creatinine,
        lp.bilirubin,
        lp.platelets,
        lp.wbc,
        lp.lactate,
        lp.bicarbonate

    from cohort c
    inner join treatment t using (stay_id)
    left join lab_pivoted lp using (stay_id)

    -- exclude patients who received neither treatment
    where t.treatment_group is not null
)

select * from final