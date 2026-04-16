SET NOCOUNT ON;
SELECT
    DB_NAME(ps.database_id) AS database_name,
    ps.object_id,
    OBJECT_NAME(ps.object_id, ps.database_id) AS procedure_name,
    SUBSTRING(st.text, 1, 300) AS proc_text_preview,
    ps.execution_count,
    ps.total_worker_time / 1000 AS total_cpu_ms,
    ps.total_worker_time / NULLIF(ps.execution_count, 0) / 1000 AS avg_cpu_ms,
    ps.total_elapsed_time / 1000 AS total_elapsed_ms,
    ps.total_elapsed_time / NULLIF(ps.execution_count, 0) / 1000 AS avg_elapsed_ms,
    ps.total_logical_reads,
    ps.total_logical_reads / NULLIF(ps.execution_count, 0) AS avg_logical_reads,
    ps.total_physical_reads,
    ps.total_logical_writes,
    ps.cached_time,
    ps.last_execution_time
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_sql_text(ps.sql_handle) st
WHERE ps.database_id = DB_ID('IntertoyERP')
ORDER BY ps.total_worker_time DESC;
