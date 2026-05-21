SELECT DISTINCT n.duid
FROM   next_day_gen n
WHERE  NOT EXISTS (
    SELECT 1
    FROM   du_detail_summary d
    WHERE  d.duid = n.duid
      AND  d.region_id IS NOT NULL
);
-- If returned rows > 0, there are DUID of unknown region.
