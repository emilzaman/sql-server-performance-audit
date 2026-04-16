/*
  15-server-health.sql
  --------------------
  Quick server health scan covering the checks most commonly missed
  in a performance audit. Runs as multiple independent result sets.

  Checks:
    A. Databases without a FULL backup in the last 7 days
    B. Databases with AUTO_CLOSE or AUTO_SHRINK enabled
    C. Databases not using PAGE_VERIFY = CHECKSUM
    D. Databases below SQL Server 2016 compatibility level (< 130)
    E. sysadmin login count (security hygiene)
    F. Logins with CONTROL SERVER permission (equivalent to sysadmin)
    G. Tables with lock escalation DISABLE (can cause excessive lock counts)
    H. Server-level triggers (can silently add overhead to every DDL)
    I. Linked servers (latency risk if queries cross linked servers)
    J. Last wait stats clear (detects DBCC SQLPERF resets that invalidate baselines)

  Each check is a standalone SELECT — skip any that are not relevant.
  All queries are read-only (no changes to server state).

  Inspired by sp_Blitz (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query set.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- ============================================================================
-- A. Databases missing a FULL backup in the last 7 days
--    (read from msdb — requires VIEW SERVER STATE or msdb access)
-- ============================================================================
PRINT '-- A. Databases without a FULL backup in the last 7 days';

SELECT
    d.name              AS database_name,
    d.recovery_model_desc,
    MAX(b.backup_finish_date) AS last_full_backup,
    DATEDIFF(DAY, MAX(b.backup_finish_date), GETDATE())
                        AS days_since_backup
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
    ON  d.name = b.database_name
    AND b.type = 'D'        -- D = Full backup
WHERE
    d.name NOT IN ('tempdb')
    AND d.state_desc = 'ONLINE'
GROUP BY d.name, d.recovery_model_desc
HAVING
    MAX(b.backup_finish_date) IS NULL               -- never backed up
    OR MAX(b.backup_finish_date) < DATEADD(DAY, -7, GETDATE())
ORDER BY days_since_backup DESC;

-- ============================================================================
-- B. Databases with AUTO_CLOSE or AUTO_SHRINK enabled
--    AUTO_CLOSE: drops and reloads the database on each connection — huge overhead
--    AUTO_SHRINK: constantly shrinks then re-grows data files — causes fragmentation
-- ============================================================================
PRINT '-- B. AUTO_CLOSE / AUTO_SHRINK';

SELECT
    name,
    is_auto_close_on    AS auto_close,
    is_auto_shrink_on   AS auto_shrink,
    state_desc
FROM sys.databases
WHERE is_auto_close_on = 1 OR is_auto_shrink_on = 1
ORDER BY name;

-- ============================================================================
-- C. Databases not using PAGE_VERIFY = CHECKSUM
--    CHECKSUM detects torn pages and storage corruption on read.
--    TORN_PAGE_DETECTION is weaker; NONE is dangerous.
-- ============================================================================
PRINT '-- C. PAGE_VERIFY not CHECKSUM';

SELECT
    name,
    page_verify_option_desc,
    state_desc
FROM sys.databases
WHERE page_verify_option_desc <> 'CHECKSUM'
  AND name <> 'tempdb'
  AND state_desc = 'ONLINE'
ORDER BY name;

-- ============================================================================
-- D. Databases below SQL Server 2016 compatibility level (< 130)
--    Old compat levels disable query optimizer improvements from newer builds.
--    Common after version upgrades where compat level is not updated.
-- ============================================================================
PRINT '-- D. Compatibility level below 130 (SQL 2016)';

SELECT
    name,
    compatibility_level,
    CASE compatibility_level
        WHEN 80  THEN 'SQL 2000'
        WHEN 90  THEN 'SQL 2005'
        WHEN 100 THEN 'SQL 2008/R2'
        WHEN 110 THEN 'SQL 2012'
        WHEN 120 THEN 'SQL 2014'
        WHEN 130 THEN 'SQL 2016'
        WHEN 140 THEN 'SQL 2017'
        WHEN 150 THEN 'SQL 2019'
        WHEN 160 THEN 'SQL 2022'
        ELSE          CAST(compatibility_level AS VARCHAR(10))
    END                 AS compat_level_name,
    state_desc
FROM sys.databases
WHERE compatibility_level < 130
  AND state_desc = 'ONLINE'
  AND name NOT IN ('master', 'model', 'msdb', 'tempdb')
ORDER BY compatibility_level, name;

-- ============================================================================
-- E. sysadmin login count
--    Any login in sysadmin has full server control.
--    More than 3-5 is unusual and worth reviewing.
-- ============================================================================
PRINT '-- E. sysadmin logins';

SELECT
    sp.name             AS login_name,
    sp.type_desc        AS login_type,
    sp.is_disabled,
    sp.create_date,
    sp.modify_date
FROM sys.server_principals AS sp
JOIN sys.server_role_members AS rm ON sp.principal_id = rm.member_principal_id
JOIN sys.server_principals AS role ON rm.role_principal_id = role.principal_id
WHERE role.name = 'sysadmin'
ORDER BY sp.type_desc, sp.name;

-- ============================================================================
-- F. Logins with CONTROL SERVER permission (equivalent to sysadmin via grant)
-- ============================================================================
PRINT '-- F. CONTROL SERVER permission grants';

SELECT
    sp.name             AS login_name,
    sp.type_desc,
    p.permission_name,
    p.state_desc        AS grant_state
FROM sys.server_principals AS sp
JOIN sys.server_permissions AS p ON sp.principal_id = p.grantee_principal_id
WHERE p.permission_name = 'CONTROL SERVER'
  AND p.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION')
ORDER BY sp.name;

-- ============================================================================
-- G. Tables with lock escalation DISABLE
--    DISABLE prevents lock escalation to table level, so SQL Server
--    accumulates row/page locks instead. On large update/delete operations
--    this can result in millions of row locks → memory pressure.
-- ============================================================================
PRINT '-- G. Tables with LOCK_ESCALATION = DISABLE';

SELECT
    DB_NAME()           AS database_name,
    s.name              AS schema_name,
    t.name              AS table_name,
    t.lock_escalation_desc,
    p.rows              AS approx_row_count
FROM sys.tables AS t
JOIN sys.schemas AS s ON t.schema_id = s.schema_id
JOIN sys.partitions AS p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
WHERE t.lock_escalation_desc = 'DISABLE'
ORDER BY p.rows DESC;

-- ============================================================================
-- H. Server-level DDL triggers
--    Server triggers fire on every DDL event across the instance.
--    Easy to forget; adds overhead to CREATE/ALTER/DROP everywhere.
-- ============================================================================
PRINT '-- H. Server-level triggers';

SELECT
    name,
    type_desc,
    is_disabled,
    create_date,
    modify_date,
    parent_class_desc
FROM sys.server_triggers
ORDER BY name;

-- ============================================================================
-- I. Linked servers
--    Linked server queries add network latency and complicate query plans.
--    Useful to know they exist before optimizing queries that cross servers.
-- ============================================================================
PRINT '-- I. Linked servers';

SELECT
    name                AS linked_server,
    product,
    provider,
    data_source,
    is_remote_login_enabled,
    is_rpc_out_enabled,
    modify_date
FROM sys.servers
WHERE is_linked = 1
ORDER BY name;

-- ============================================================================
-- J. Last wait stats clear (DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR))
--    Cleared wait stats invalidate our baseline DMV data.
--    This check looks at idle waits that should always accumulate.
--    If the MAX is very low, stats were cleared recently.
-- ============================================================================
PRINT '-- J. Wait stats clear detector (idle wait accumulation check)';

SELECT
    wait_type,
    wait_time_ms,
    waiting_tasks_count,
    -- If max_wait_ms is < 60000 (1 min), stats may have been cleared recently
    CASE WHEN wait_time_ms < 60000
         THEN 'WARNING: may have been cleared recently'
         ELSE 'OK'
    END                 AS status
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    'SLEEP_DBSTARTUP',
    'SLEEP_DBRESTORE',
    'SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED',
    'SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK',
    'SLEEP_TEMPDBSTARTUP',
    'DIRTY_PAGE_POLL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'LAZYWRITER_SLEEP',
    'LOGMGR_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
)
ORDER BY wait_time_ms ASC;
