with distinct_time as (select distinct end_time
                       from dispatched_scada)
select date(end_time) as date_
from distinct_time
group by date_
having count(*) = 288