SET NOCOUNT ON;
SELECT
    OBJECT_NAME(ius.object_id, ius.database_id) AS table_name,
    i.name AS index_name,
    i.type_desc AS index_type,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,
    ius.last_user_seek,
    ius.last_user_scan,
    ius.last_user_lookup,
    ius.last_user_update,
    CASE
        WHEN (ius.user_seeks + ius.user_scans + ius.user_lookups) = 0 AND ius.user_updates > 0
        THEN 'UNUSED - candidate for removal'
        WHEN ius.user_updates > (ius.user_seeks + ius.user_scans + ius.user_lookups) * 10
        THEN 'LOW VALUE - writes >> reads'
        ELSE 'ACTIVE'
    END AS usage_status
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.database_id = DB_ID('IntertoyERP')
    AND i.name IS NOT NULL
ORDER BY (ius.user_seeks + ius.user_scans + ius.user_lookups) ASC;
