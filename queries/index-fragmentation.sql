/*
  index-fragmentation.sql
  -----------------------
  Indexes with high fragmentation AND significant size.
  Also shows write-to-read ratio from sys.dm_db_index_operational_stats
  to help decide whether a fragmented index is worth rebuilding.

  *** PERFORMANCE NOTE — read before running ***
  sys.dm_db_index_physical_stats is expensive on large databases (> 500 GB).
  On a 2 TB DB with 6,000+ indexes, even LIMITED mode can take 30+ minutes
  if run against all objects. This script uses a TWO-STEP approach:

    Step 1: Identify tables > 1 GB using partition_stats (instant, in-memory).
    Step 2: Run dm_db_index_physical_stats only against those tables via
            CROSS APPLY with object_id list (LIMITED mode, fast per-table).

  This typically returns results in 2-5 minutes on a 2 TB database with
  ~120 large tables. For databases < 200 GB, remove the #large_objects
  filter and run against all objects directly.

  Mode: LIMITED (allocation pages only — fast, ~1-3% accuracy variance vs SAMPLED)
  For precise fragmentation on a specific index, use DETAILED mode targeted
  at that single object_id.

  Filter defaults:
    - fragmentation > 10%  (< 10% is generally not worth acting on)
    - index size    > 128 pages (1 MB)   — tiny indexes don't matter
    - table size    > 128,000 pages (1 GB) — skip small tables entirely

  Columns:
    schema_name, table_name, index_name
    index_type_desc          — HEAP / CLUSTERED / NONCLUSTERED
    avg_fragmentation_pct    — avg page fragmentation percent
    page_count               — index size in pages (× 8 KB)
    size_MB
    leaf_updates_per_seek    — write amplification proxy:
                               > 10 means this index is written far more than read
    total_reads              — seeks + scans + lookups since last restart
    total_writes             — user_updates since last restart
    action                   — REBUILD (>= 30%) / REORGANIZE (10-29%) / OK

  Inspired by sp_BlitzIndex (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query — no stored procedure scaffolding.
*/

USE [master];     -- change to target database
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @db_id INT = DB_ID();

-- Step 1: find tables > 1 GB (adjust threshold as needed)
IF OBJECT_ID('tempdb..#large_objects') IS NOT NULL DROP TABLE #large_objects;

SELECT DISTINCT ps.object_id
INTO #large_objects
FROM sys.dm_db_partition_stats AS ps
JOIN sys.objects AS o ON ps.object_id = o.object_id
WHERE o.is_ms_shipped = 0
GROUP BY ps.object_id
HAVING SUM(ps.reserved_page_count) > 128000;   -- > 1 GB

-- Step 2: scan only those tables in LIMITED mode
SELECT
    s.name                                              AS schema_name,
    t.name                                              AS table_name,
    i.name                                              AS index_name,
    ips.index_type_desc,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1))
                                                        AS avg_fragmentation_pct,
    ips.page_count,
    CAST(ips.page_count * 8.0 / 1024 AS DECIMAL(10,1)) AS size_MB,

    -- Write amplification proxy
    CAST(
        ISNULL(ios.leaf_update_count, 0) * 1.0
        / NULLIF(ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0), 0)
    AS DECIMAL(10,1))                                   AS leaf_updates_per_seek,

    ISNULL(us.user_seeks, 0)
        + ISNULL(us.user_scans, 0)
        + ISNULL(us.user_lookups, 0)                    AS total_reads,
    ISNULL(us.user_updates, 0)                          AS total_writes,

    CASE
        WHEN ips.avg_fragmentation_in_percent >= 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent >= 10 THEN 'REORGANIZE'
        ELSE 'OK'
    END                                                 AS action

FROM #large_objects AS lo
CROSS APPLY sys.dm_db_index_physical_stats(
    @db_id,
    lo.object_id,
    NULL,       -- all indexes on this table
    NULL,       -- all partitions
    'LIMITED'   -- fastest mode; use 'SAMPLED' for better accuracy on < 200 GB DBs
) AS ips

JOIN sys.indexes  AS i  ON ips.object_id = i.object_id AND ips.index_id = i.index_id
JOIN sys.objects  AS t  ON i.object_id   = t.object_id
JOIN sys.schemas  AS s  ON t.schema_id   = s.schema_id

LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.database_id = @db_id
    AND us.object_id   = i.object_id
    AND us.index_id    = i.index_id

LEFT JOIN sys.dm_db_index_operational_stats(@db_id, NULL, NULL, NULL) AS ios
    ON  ios.object_id        = i.object_id
    AND ios.index_id         = i.index_id
    AND ios.partition_number = ips.partition_number

WHERE
    i.type                               IN (0, 1, 2)  -- HEAP, CLUSTERED, NONCLUSTERED
    AND ips.page_count                    > 128         -- > 1 MB
    AND ips.avg_fragmentation_in_percent  > 10

ORDER BY
    ips.avg_fragmentation_in_percent DESC,
    ips.page_count DESC;

DROP TABLE #large_objects;
