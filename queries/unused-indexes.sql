/*
============================================================================
  UNUSED / LOW-USAGE INDEXES
  Use: find indexes that cost writes but deliver no reads.
  A "stale" baseline: server uptime >= 30 days AND user_seeks+user_scans = 0.
  Drop candidates must also check sys.dm_db_index_usage_stats is NOT lost
  after SQL restart — never drop based on a fresh restart.

  Output: per-index usage, size, and a drop risk level.
============================================================================
*/

USE [<<DATABASE_NAME>>];
GO

SELECT
    DB_NAME()                                           AS database_name,
    OBJECT_SCHEMA_NAME(i.object_id)                     AS schema_name,
    OBJECT_NAME(i.object_id)                            AS table_name,
    i.name                                              AS index_name,
    i.type_desc                                         AS index_type,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,
    ius.last_user_seek,
    ius.last_user_scan,
    ius.last_user_lookup,
    ps.used_page_count * 8 / 1024                       AS size_mb,
    CASE
        WHEN ius.user_seeks IS NULL
             AND ius.user_scans IS NULL
             AND ius.user_lookups IS NULL THEN 'NEVER_READ_SINCE_RESTART'
        WHEN (ius.user_seeks + ius.user_scans + ius.user_lookups) = 0 THEN 'NEVER_READ'
        WHEN (ius.user_seeks + ius.user_scans + ius.user_lookups)
             < ius.user_updates / 100                  THEN 'WRITE_DOMINATED'
        ELSE 'USED'
    END                                                 AS usage_class
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps
      ON i.object_id = ps.object_id AND i.index_id = ps.index_id
LEFT JOIN sys.dm_db_index_usage_stats ius
      ON  i.object_id = ius.object_id
      AND i.index_id  = ius.index_id
      AND ius.database_id = DB_ID()
WHERE i.type > 1                    -- skip heaps & clustered
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND ps.used_page_count > 1280     -- only indexes >= 10 MB worth investigating
ORDER BY ps.used_page_count DESC;
