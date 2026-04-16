/*
============================================================================
  PLAN CACHE COMPOSITION — by cache class and single-use plans
  Use: identify whether cache bloat is Adhoc, Prepared, or Proc class.
  Adhoc bloat is fixed by "Optimize for Ad Hoc Workloads"; Prepared bloat
  is NOT fixed by that setting — it requires client-side parameterization
  or database-level FORCED parameterization.
============================================================================
*/

SELECT
    objtype                                                           AS cache_class,
    COUNT(*)                                                          AS plans,
    SUM(CAST(size_in_bytes AS bigint)) / 1024 / 1024                  AS total_mb,
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)                    AS single_use_plans,
    SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS bigint)
             ELSE 0 END) / 1024 / 1024                                AS single_use_mb
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY total_mb DESC;
