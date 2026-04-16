SET NOCOUNT ON;
SELECT
    ps.object_id,
    DB_NAME(ps.database_id) AS database_name,
    OBJECT_NAME(ps.object_id, ps.database_id) AS procedure_name_resolved,
    SUBSTRING(st.text,
        CHARINDEX('procedure', LOWER(st.text)) + 10,
        CHARINDEX(CHAR(13), st.text + CHAR(13), CHARINDEX('procedure', LOWER(st.text)) + 10) - CHARINDEX('procedure', LOWER(st.text)) - 10
    ) AS procedure_name_from_text,
    ps.execution_count,
    ps.total_worker_time / 1000 AS total_cpu_ms,
    ps.total_worker_time / NULLIF(ps.execution_count, 0) / 1000 AS avg_cpu_ms,
    ps.total_elapsed_time / 1000 AS total_elapsed_ms,
    ps.total_elapsed_time / NULLIF(ps.execution_count, 0) / 1000 AS avg_elapsed_ms,
    ps.total_logical_reads,
    ps.total_logical_reads / NULLIF(ps.execution_count, 0) AS avg_logical_reads,
    ps.total_physical_reads,
    ps.total_physical_reads / NULLIF(ps.execution_count, 0) AS avg_physical_reads,
    ps.total_logical_writes,
    ps.max_elapsed_time / 1000 AS max_elapsed_ms,
    ps.min_elapsed_time / 1000 AS min_elapsed_ms,
    ps.max_worker_time / 1000 AS max_cpu_ms,
    ps.max_logical_reads AS max_logical_reads,
    ps.cached_time,
    ps.last_execution_time,
    -- Impact score: frequency * avg_duration_sec * avg_reads / 1M
    CAST(
        ps.execution_count *
        (ps.total_elapsed_time / NULLIF(ps.execution_count, 0) / 1000000.0) *
        (ps.total_logical_reads / NULLIF(ps.execution_count, 0) / 1000000.0)
    AS DECIMAL(18,4)) AS impact_score
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_sql_text(ps.sql_handle) st
WHERE ps.database_id = DB_ID('IntertoyERP')
ORDER BY ps.total_worker_time DESC;
