with source as (
    select * from {{ source('hosp', 'diagnoses_icd') }}
),

renamed as (
    select
        subject_id,
        hadm_id,
        seq_num,          -- 1 = primary diagnosis
        icd_code,
        icd_version       -- 9 or 10
    from source
),

-- Flag sepsis codes upfront so the cohort model stays clean
sepsis_flagged as (
    select
        *,
        case
            when icd_version = 10 and icd_code in (
                'A419',   -- Sepsis, unspecified organism
                'A41.9',
                'A410',   'A41.0',  -- Sepsis due to Staph aureus
                'A411',   'A41.1',  -- Sepsis due to other staph
                'A4150',  'A41.50', -- Gram-negative sepsis
                'A4151',  'A41.51',
                'A4152',  'A41.52',
                'A4153',  'A41.53',
                'A4159',  'A41.59',
                'R6520',  'R65.20', -- Severe sepsis without septic shock
                'R6521',  'R65.21'  -- Severe sepsis with septic shock
            ) then 1
            when icd_version = 9 and icd_code in (
                '99591',  -- Sepsis
                '99592'   -- Severe sepsis
            ) then 1
            else 0
        end as is_sepsis_dx

    from renamed
)

select * from sepsis_flagged