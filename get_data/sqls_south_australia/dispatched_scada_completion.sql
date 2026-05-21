WITH statistics AS (
    SELECT MIN(end_time) AS start_time, MAX(end_time) AS end_time
    FROM dispatched_scada
),
distinct_time as (
    select distinct end_time from dispatched_scada
),
     series(datetime_) AS (
         SELECT start_time FROM statistics
         UNION ALL
         SELECT datetime(datetime_, '+5 minutes')
         FROM series
         WHERE datetime_ < (SELECT end_time FROM statistics) -- still inclusive
     )
SELECT datetime_ FROM series
WHERE not exists (
    select 1
    from distinct_time
    where datetime_ = distinct_time.end_time
)
-- Expect 0 row if data is completed