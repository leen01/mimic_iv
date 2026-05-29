with source as (
    select * from {{ source('icu', 'icustays') }}
),

renamed as (
    select
        subject_id,
        hadm_id,
        stay_id,
        first_careunit,
        last_careunit,
        intime                                                  as icu_intime,
        outtime                                                 as icu_outtime,
        datediff('hour', intime, outtime) / 24.0               as icu_los_days,

        -- flag first ICU stay per admission (we'll use this for index date)
        row_number() over (
            partition by hadm_id
            order by intime asc
        )                                                       as icu_stay_seq

    from source
)

select * from renamed