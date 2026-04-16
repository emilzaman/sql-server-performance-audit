/*
  active-transactions.sql
  -----------------------
  Open transactions with duration, session details, and current wait.

  Long-running or abandoned open transactions:
    - Hold locks → cause blocking chains
    - Inflate the transaction log (log cannot truncate past the oldest active txn)
    - In RCSI/Snapshot databases, inflate the version store in TempDB

  Columns:
    session_id
    transaction_id
    txn_name             — system-generated name (often blank for user txns)
    txn_type             — Read/Write/Distributed/ValueType
    txn_state            — Active/Aborted/Committed In Memory/etc.
    txn_duration_sec     — seconds since BEGIN TRANSACTION
    is_user_transaction  — 1 = explicit user transaction
    database_name        — database context
    login_name, host_name, program_name
    request_status       — running/sleeping/background (NULL = session is idle
                           but has an open transaction — most dangerous case)
    blocking_session     — who this session is blocked by
    current_wait_type    — what the active request is waiting on
    logical_reads        — cumulative reads for the current request
    query_text           — current or most recent SQL (first 300 chars)

  Sort order: longest-running transactions first.

  Inspired by sp_BlitzWho + sp_BlitzFirst (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    tst.session_id,
    tat.transaction_id,
    NULLIF(tat.name, '')                                    AS txn_name,
    CASE tat.transaction_type
        WHEN 1 THEN 'Read/Write'
        WHEN 2 THEN 'Read-Only'
        WHEN 3 THEN 'System'
        WHEN 4 THEN 'Distributed'
        ELSE        CAST(tat.transaction_type AS VARCHAR(10))
    END                                                     AS txn_type,
    CASE tat.transaction_state
        WHEN 0 THEN 'Initializing'
        WHEN 1 THEN 'Initialized'
        WHEN 2 THEN 'Active'
        WHEN 3 THEN 'Ended (read-only)'
        WHEN 4 THEN 'DTC commit started'
        WHEN 5 THEN 'Awaiting resolution'
        WHEN 6 THEN 'Committed'
        WHEN 7 THEN 'Rolling back'
        WHEN 8 THEN 'Rolled back'
        ELSE        CAST(tat.transaction_state AS VARCHAR(10))
    END                                                     AS txn_state,
    DATEDIFF(SECOND, tat.transaction_begin_time, GETDATE())
                                                            AS txn_duration_sec,
    tst.is_user_transaction,
    tst.is_local,

    DB_NAME(r.database_id)                                  AS database_name,
    s.login_name,
    s.host_name,
    s.program_name,

    -- NULL request_status = session is idle but has an open txn
    -- This is the most dangerous case: holds locks, blocks others
    r.status                                                AS request_status,
    r.blocking_session_id                                   AS blocking_session,
    r.wait_type                                             AS current_wait_type,
    r.wait_time                                             AS wait_time_ms,
    r.logical_reads,

    CAST(SUBSTRING(
        ISNULL(t.text, ''),
        ISNULL(r.statement_start_offset / 2, 0) + 1,
        CASE r.statement_end_offset
            WHEN -1 THEN LEN(ISNULL(t.text, ''))
            ELSE r.statement_end_offset / 2 - ISNULL(r.statement_start_offset / 2, 0)
        END
    ) AS NVARCHAR(300))                                     AS query_text

FROM sys.dm_tran_active_transactions    AS tat
JOIN sys.dm_tran_session_transactions   AS tst ON tat.transaction_id = tst.transaction_id
JOIN sys.dm_exec_sessions               AS s   ON tst.session_id     = s.session_id

LEFT JOIN sys.dm_exec_requests          AS r   ON tst.session_id     = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t

WHERE
    tst.is_user_transaction = 1     -- skip system transactions
    AND s.session_id <> @@SPID

ORDER BY
    txn_duration_sec DESC,
    tst.session_id;
