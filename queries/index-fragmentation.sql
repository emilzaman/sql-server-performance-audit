/*
  index-fragmentation.sql
  -----------------------
  Indexes with high fragmentation AND significant size.
  Also shows write-to-read ratio from sys.dm_db_index_operational_stats
  to help decide whether a fragmented index is worth rebuilding.

  Run in SAMPLED mode (fast — reads only the index B-tree top level for
  fragmentation estimate). For precise numbers on a specific index use
  DETAILED, but that locks the table longer.

  Filter defaults:
    - fragmentation > 10%  (< 10% fragmentation is generally not worth acting on)
    - index size   > 128 pages (1 MB)   — tiny indexes don't matter

  Columns:
    schema_name, table_name, index_name
    index_type_desc          — HEAP / CLUSTERED / NONCLUSTERED
    avg_fragmentation_%      — avg page fragmentation in percent
    page_count               — index size in pages (× 8 KB)
    size_MB
    avg_page_space_%         — how full each page is (low = internal fragmentation)
    leaf_updates_per_seek    — write amplification proxy:
                               > 10 means this index is written far more than read
    total_reads              — seeks + scans + lookups since last restart
    total_writes             — user_updates since last restart
    rebuild_or_reorganize    — advisory: REBUILD if > 30%, REORGANIZE if 10-30%

  Inspired by sp_BlitzIndex (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query — no stored procedure scaffolding.
*/

USE [master];     -- change to target database
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @db_id INT = DB_ID();   -- run against target database

SELECT
    s.name                                          AS schema_name,
    t.name                                          AS table_name,
    i.name                                          AS index_name,
    ips.index_type_desc,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1))
                                                    AS avg_fragmentation_pct,
    ips.page_count,
    CAST(ips.page_count * 8.0 / 1024 AS DECIMAL(10,1))
                                                    AS size_MB,
    CAST(ips.avg_page_space_used_in_percent AS DECIMAL(5,1))
                                                    AS avg_page_space_pct,

    -- Write amplification proxy: how many leaf-level modifications
    -- per index seek/scan. High number = this index pays a lot in writes
    -- for relatively few reads — candidate to DROP rather than REBUILD.
    CAST(
        ISNULL(ios.leaf_update_count, 0) * 1.0
        / NULLIF(ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0), 0)
    AS DECIMAL(10,1))                               AS leaf_updates_per_seek,

    ISNULL(us.user_seeks, 0)
        + ISNULL(us.user_scans, 0)
        + ISNULL(us.user_lookups, 0)                AS total_reads,
    ISNULL(us.user_updates, 0)                      AS total_writes,

    CASE
        WHEN ips.avg_fragmentation_in_percent >= 30 THEN 'REBUILD'
        WHEN ips.avg_fragmentation_in_percent >= 10 THEN 'REORGANIZE'
        ELSE 'OK'
    END                                             AS rebuild_or_reorganize

FROM sys.dm_db_index_physical_stats(
        @db_id,
        NULL,   -- all objects
        NULL,   -- all indexes
        NULL,   -- all partitions
        'SAMPLED'
     ) AS ips

JOIN sys.indexes        AS i   ON ips.object_id = i.object_id
                               AND ips.index_id  = i.index_id
JOIN sys.objects        AS t   ON i.object_id    = t.object_id
JOIN sys.schemas        AS s   ON t.schema_id    = s.schema_id

LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON  us.database_id = @db_id
    AND us.object_id   = i.object_id
    AND us.index_id    = i.index_id

LEFT JOIN sys.dm_db_index_operational_stats(@db_id, NULL, NULL, NULL) AS ios
    ON  ios.object_id        = i.object_id
    AND ios.index_id         = i.index_id
    AND ios.partition_number = ips.partition_number

WHERE
    t.is_ms_shipped              = 0
    AND i.type                  IN (0, 1, 2)    -- HEAP, CLUSTERED, NONCLUSTERED
    AND ips.page_count           > 128          -- > 1 MB
    AND ips.avg_fragmentation_in_percent > 10

ORDER BY
    ips.avg_fragmentation_in_percent DESC,
    ips.page_count DESC;
