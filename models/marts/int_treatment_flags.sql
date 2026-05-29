/*
  Treatment flags — vasopressor vs fluid resuscitation
  ------------------------------------------------------
  Exposure A : Vasopressor use (norepinephrine, epinephrine, dopamine,
               vasopressin, phenylephrine) within 24h of ICU admission
  Exposure B : Fluid resuscitation only (crystalloids/colloids, no vasopressors)
  Index date : ICU admission (icu_intime from int_sepsis_cohort)
  Window     : First 24 hours of ICU stay only
  
  Treatment groups
    vasopressor = 1, fluid_only = 0
  Patients who received neither are excluded downstream in mart_analysis_cohort
*/

with cohort as (
    select
        subject_id,
        hadm_id,
        stay_id,
        index_date
    from {{ ref('int_sepsis_cohort') }}
),

inputevents as (
    select * from {{ source('icu', 'inputevents') }}
),

d_items as (
    select * from {{ source('icu', 'd_items') }}
),

-- tag every input item as vasopressor or fluid
labeled_inputs as (
    select
        ie.subject_id,
        ie.hadm_id,
        ie.stay_id,
        ie.starttime,
        ie.amount,
        ie.amountuom,
        di.label,
        di.itemid,

        case
            when di.itemid in (
                221906,  -- norepinephrine
                221289,  -- epinephrine
                221662,  -- dopamine
                222315,  -- vasopressin
                221749   -- phenylephrine
            ) then 'vasopressor'

            when di.itemid in (
                -- crystalloids
                225158,  -- NaCl 0.9%
                225159,  -- NaCl 0.45%
                225161,  -- NaCl 3%
                220949,  -- dextrose 5%
                225828,  -- lactated ringers
                225827,  -- sterile water
                -- colloids
                220864,  -- albumin 5%
                220862,  -- albumin 25%
                225174,  -- hetastarch
                225975,  -- plasma
                225976   -- platelets
            ) then 'fluid'

            else 'other'
        end as input_category

    from inputevents ie
    inner join d_items di using (itemid)
),

-- restrict to first 24h window per stay
inputs_24h as (
    select
        li.subject_id,
        li.hadm_id,
        li.stay_id,
        li.starttime,
        li.input_category,
        li.label,
        li.itemid,
        li.amount,
        li.amountuom

    from labeled_inputs li
    inner join cohort c using (stay_id)

    where
        li.starttime >= c.index_date
        and li.starttime < dateadd('hour', 24, c.index_date)
        and li.input_category in ('vasopressor', 'fluid')
),

-- aggregate to one row per stay
stay_flags as (
    select
        stay_id,
        max(case when input_category = 'vasopressor' then 1 else 0 end)
                                                as received_vasopressor,
        max(case when input_category = 'fluid' then 1 else 0 end)
                                                as received_fluid,

        -- total fluid volume in ml (useful covariate)
        sum(case
            when input_category = 'fluid'
            and amountuom = 'ml'
            then amount else 0
        end)                                    as total_fluid_ml,

        -- count distinct vasopressors (severity signal)
        count(distinct case
            when input_category = 'vasopressor'
            then itemid end
        )                                       as vasopressor_count,

        -- time to first vasopressor in hours (severity signal)
        min(case
            when input_category = 'vasopressor'
            then starttime end
        )                                       as first_vasopressor_time

    from inputs_24h
    group by stay_id
),

final as (
    select
        c.subject_id,
        c.hadm_id,
        c.stay_id,
        c.index_date,

        coalesce(sf.received_vasopressor, 0)    as received_vasopressor,
        coalesce(sf.received_fluid, 0)          as received_fluid,
        coalesce(sf.total_fluid_ml, 0)          as total_fluid_ml,
        coalesce(sf.vasopressor_count, 0)       as vasopressor_count,
        sf.first_vasopressor_time,

        -- treatment group assignment
        -- 1 = vasopressor, 0 = fluid only, null = neither (excluded later)
        case
            when coalesce(sf.received_vasopressor, 0) = 1 then 1
            when coalesce(sf.received_vasopressor, 0) = 0
             and coalesce(sf.received_fluid, 0) = 1      then 0
            else null
        end                                     as treatment_group,

        case
            when coalesce(sf.received_vasopressor, 0) = 1 then 'vasopressor'
            when coalesce(sf.received_vasopressor, 0) = 0
             and coalesce(sf.received_fluid, 0) = 1      then 'fluid_only'
            else 'neither'
        end                                     as treatment_label

    from cohort c
    left join stay_flags sf using (stay_id)
)

select * from final