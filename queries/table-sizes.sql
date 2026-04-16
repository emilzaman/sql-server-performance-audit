/*
============================================================================
  TABLE AND INDEX SIZES
  Use: risk-weight index changes by table size. Anything > 100M rows gets
  extra caution for ONLINE build + tempdb sizing.
============================================================================
*/

USE [<<DATABASE_NAME>>];
GO

SELECT TOP 50
    OBJECT_SCHEMA_NAME(ps.object_id)                           AS schema_name,
    OBJECT_NAME(ps.object_id)                                  AS table_name,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS row_count,
    SUM(ps.reserved_page_count) * 8 / 1024                     AS total_mb,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.used_page_count ELSE 0 END) * 8 / 1024 AS data_mb,
    SUM(CASE WHEN ps.index_id > 1     THEN ps.used_page_count ELSE 0 END) * 8 / 1024 AS nc_index_mb,
    COUNT(DISTINCT ps.index_id)                                AS index_count
FROM sys.dm_db_partition_stats ps
JOIN sys.objects o ON ps.object_id = o.object_id AND o.type = 'U'
GROUP BY ps.object_id
ORDER BY SUM(ps.reserved_page_count) DESC;
