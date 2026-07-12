-- AEMO NEMWEB Dispatch_SCADA: rows younger than 3 days (AEST, UTC+10, no DST)
-- are moved to the Archive folder. Filter to those still in the Current folder.
with distinct_time as (select distinct end_time
                       from dispatched_scada)
select end_time
from distinct_time
where end_time >= datetime('now', '+10 hours', '-3 days')
