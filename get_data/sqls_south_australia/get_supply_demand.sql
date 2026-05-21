with non_scheduled_supply_table as (
-- reason of "-1": The column is ending time, so the end of time block (e.g. x:30
-- when sampling frequency is 30 minutes) represents the period before (x:00~x:30).
-- Division without "-1" will make the end of time block be grouped to the next period.
    select ceil((strftime('%s', next_day_gen.end_time) - 1) / 1800) as end_time_30min,
           -- After resampled (0.5h), power = energy / time (0.5h)
           sum(energy) * 2 as non_scheduled_supply_load
    from next_day_gen join du_detail_summary
                           on next_day_gen.duid = du_detail_summary.duid
    where du_detail_summary.region_id = 'NSW1'
    group by end_time_30min
),
     demand_table as (
         select ceil((strftime('%s', end_time) - 1) / 1800) as end_time_30min,
                load as demand_load
         from historical_demand
         where region_id = 'NSW1'
     )
select datetime(demand_table.end_time_30min * 1800, 'unixepoch') as timestamp,
       non_scheduled_supply_load, demand_load
from non_scheduled_supply_table join demand_table
    on non_scheduled_supply_table.end_time_30min = demand_table.end_time_30min
