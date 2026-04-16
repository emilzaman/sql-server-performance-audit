/*
============================================================================
  PLAN CACHE TOP OFFENDERS — find unparameterized INSERTs / UPDATEs
  Use: after plan-cache-composition.sql shows Prepared bloat, run this to
  find which specific statements are duplicated 100s/1000s of times.
  Truncates SQL text to 300 chars so the output is readable.
============================================================================
*/

SELECT TOP 30
    LEFT(SUBSTRING(st.text, 1, 300), 300) AS target,
    COUNT(*)                              AS plan_count,
    SUM(CAST(cp.size_in_bytes AS bigint)) / 1024.0 / 1024.0 AS total_mb
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
WHERE cp.objtype = 'Prepared'
  AND cp.usecounts = 1
GROUP BY LEFT(SUBSTRING(st.text, 1, 300), 300)
ORDER BY total_mb DESC;
