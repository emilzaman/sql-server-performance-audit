SET NOCOUNT ON;
SELECT
    DB_NAME(vfs.database_id) AS database_name,
    mf.name AS file_name,
    mf.physical_name,
    mf.type_desc AS file_type,
    vfs.num_of_reads,
    vfs.num_of_bytes_read / 1048576 AS read_mb,
    vfs.io_stall_read_ms,
    CASE WHEN vfs.num_of_reads > 0 THEN vfs.io_stall_read_ms / vfs.num_of_reads ELSE 0 END AS avg_read_stall_ms,
    vfs.num_of_writes,
    vfs.num_of_bytes_written / 1048576 AS write_mb,
    vfs.io_stall_write_ms,
    CASE WHEN vfs.num_of_writes > 0 THEN vfs.io_stall_write_ms / vfs.num_of_writes ELSE 0 END AS avg_write_stall_ms,
    vfs.io_stall AS total_io_stall_ms,
    vfs.size_on_disk_bytes / 1048576 AS size_on_disk_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
WHERE vfs.database_id = DB_ID('IntertoyERP')
ORDER BY vfs.io_stall DESC;
