/*
============================================================================
  MEMORY CLERKS — who is using server RAM
  Use: understand buffer pool vs plan cache vs lock manager split.
  Critical when buffer pool shows low cache ratio (< 20% of DB size in RAM).
============================================================================
*/

SELECT TOP 20
    type                                                    AS clerk_type,
    name                                                    AS clerk_name,
    SUM(pages_kb)                              / 1024.0     AS allocated_mb,
    SUM(virtual_memory_committed_kb)           / 1024.0     AS vm_committed_mb,
    SUM(awe_allocated_kb)                      / 1024.0     AS awe_mb
FROM sys.dm_os_memory_clerks
GROUP BY type, name
ORDER BY SUM(pages_kb) DESC;

-- Buffer pool composition by database
SELECT
    CASE WHEN database_id = 32767 THEN 'Resource DB' ELSE DB_NAME(database_id) END AS database_name,
    COUNT(*) * 8 / 1024                                         AS buffered_mb
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY buffered_mb DESC;
