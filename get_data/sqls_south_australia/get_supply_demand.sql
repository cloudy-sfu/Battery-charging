WITH non_scheduled_supply_table_5min AS (
    SELECT datetime(CAST(
                -- C language integer division behavior, needs to convert to float first
                    ceil(strftime('%s', next_day_gen.end_time) * 1.0 / 1800)
                AS INTEGER) * 1800, 'unixepoch')
             AS end_time_30min,
           -- Aggregated across DUID; convert 5min energy to load
           sum(energy) * 12 AS sum_load
    FROM next_day_gen
             JOIN du_detail_summary ON next_day_gen.duid = du_detail_summary.duid
    WHERE du_detail_summary.region_id = :region
      AND datetime(next_day_gen.end_time)  > datetime(:start_time)
      AND datetime(next_day_gen.end_time) <= datetime(:end_time)
    GROUP BY end_time
),
 non_scheduled_supply_table AS (
     SELECT end_time_30min, avg(sum_load) AS non_scheduled_supply_load
     FROM non_scheduled_supply_table_5min
     GROUP BY end_time_30min
 ),
scheduled_supply_table_5min AS (
    SELECT datetime(CAST(
               -- C language integer division behavior, needs to convert to float first
               ceil(strftime('%s', dispatched_scada.end_time) * 1.0 / 1800)
               AS INTEGER) * 1800, 'unixepoch')
           AS end_time_30min,
           -- Aggregated across DUID
           sum(load) AS sum_load
    FROM dispatched_scada
    JOIN du_detail_summary ON dispatched_scada.duid = du_detail_summary.duid
    WHERE du_detail_summary.region_id = :region
      AND datetime(dispatched_scada.end_time)  > datetime(:start_time)
      AND datetime(dispatched_scada.end_time) <= datetime(:end_time)
    GROUP BY end_time
),
scheduled_supply_table AS (
    SELECT end_time_30min, avg(sum_load) AS scheduled_supply_load
    FROM scheduled_supply_table_5min
    GROUP BY end_time_30min
),
demand_table AS (
    SELECT end_time, load as demand_load
    FROM historical_demand
    WHERE region_id = :region
      AND datetime(end_time) > datetime(:start_time)
      AND datetime(end_time) <= datetime(:end_time)
)
SELECT demand_table.end_time,
       demand_table.demand_load,
       scheduled_supply_table.scheduled_supply_load,
       non_scheduled_supply_table.non_scheduled_supply_load
FROM demand_table
LEFT JOIN scheduled_supply_table ON demand_table.end_time = scheduled_supply_table.end_time_30min
LEFT JOIN non_scheduled_supply_table ON demand_table.end_time = non_scheduled_supply_table.end_time_30min
