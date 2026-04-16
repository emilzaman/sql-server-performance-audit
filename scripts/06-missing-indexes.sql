SET NOCOUNT ON;
SELECT
    OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.unique_compiles,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_user_impact,
    CAST(migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) AS DECIMAL(18,2)) AS improvement_measure,
    mid.statement AS full_table_path
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID('IntertoyERP')
ORDER BY improvement_measure DESC;
