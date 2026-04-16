SET NOCOUNT ON;
SELECT
    @@VERSION AS sql_version,
    sqlserver_start_time,
    cpu_count,
    physical_memory_kb / 1024 AS physical_memory_mb,
    committed_kb / 1024 AS committed_memory_mb,
    committed_target_kb / 1024 AS target_memory_mb
FROM sys.dm_os_sys_info;
