/*
============================================================================
  POST-DEPLOYMENT INDEX USAGE VERIFICATION
  Use: after creating a new index and BEFORE dropping its predecessor, run
  this to confirm: new index is used AND old index is no longer used.
  Requires 7+ days of stats since the CREATE (sys.dm_db_index_usage_stats
  resets on SQL restart).
============================================================================
*/

USE [<<DATABASE_NAME>>];
GO

SELECT
    OBJECT_NAME(i.object_id)            AS table_name,
    i.name                              AS index_name,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    s.last_user_seek,
    s.last_user_scan
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s
      ON i.object_id = s.object_id
     AND i.index_id  = s.index_id
     AND s.database_id = DB_ID()
WHERE i.name IN (
    'IX_NewIndex_Name',          -- EDIT: your new index
    'IX_OldIndex_Name'           -- EDIT: the predecessor you plan to drop
)
ORDER BY i.name;
