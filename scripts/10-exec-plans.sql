SET NOCOUNT ON;
SELECT TOP 20
    OBJECT_NAME(ps.object_id, ps.database_id) AS procedure_name,
    ps.execution_count,
    ps.total_worker_time / 1000 AS total_cpu_ms,
    ps.total_logical_reads,
    ps.total_elapsed_time / 1000 AS total_elapsed_ms,
    CAST(qp.query_plan AS NVARCHAR(MAX)) AS query_plan_xml
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_query_plan(ps.plan_handle) qp
WHERE ps.database_id = DB_ID('IntertoyERP')
ORDER BY ps.total_worker_time DESC;
