/*
============================================================================
  LIVE BLOCKING CHAINS (point-in-time)
  Use: run ad-hoc when users report "everything is stuck".
  Shows who is blocking whom, wait type, and the head-of-chain SQL text.
============================================================================
*/

;WITH blocked AS (
    SELECT
        r.session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time,
        r.wait_resource,
        r.status,
        r.command,
        r.sql_handle,
        r.statement_start_offset,
        r.statement_end_offset,
        r.database_id,
        s.login_name,
        s.host_name,
        s.program_name,
        s.last_request_start_time
    FROM sys.dm_exec_requests r
    JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    WHERE r.blocking_session_id <> 0
       OR r.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
)
SELECT
    b.session_id                                        AS spid,
    b.blocking_session_id                               AS blocked_by,
    DB_NAME(b.database_id)                              AS database_name,
    b.wait_type,
    b.wait_time / 1000.0                                AS wait_sec,
    b.wait_resource,
    b.status,
    b.login_name,
    b.host_name,
    b.program_name,
    SUBSTRING(t.text,
              (b.statement_start_offset / 2) + 1,
              ((CASE b.statement_end_offset
                      WHEN -1 THEN DATALENGTH(t.text)
                      ELSE b.statement_end_offset END
                - b.statement_start_offset) / 2) + 1)   AS current_statement
FROM blocked b
OUTER APPLY sys.dm_exec_sql_text(b.sql_handle) t
ORDER BY
    CASE WHEN b.blocking_session_id = 0 THEN 0 ELSE 1 END, -- heads first
    b.wait_time DESC;
