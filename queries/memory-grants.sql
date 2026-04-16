/*
  memory-grants.sql
  -----------------
  Shows query memory grants currently in flight — queries that have
  requested or been granted memory from the query execution memory pool.

  Large memory grants are the #1 cause of "server freezes" during
  long-running reports or batch jobs (e.g. SAF-T declarations).
  A single query granted 7 GB out of 16 GB available will starve
  everything else.

  Columns:
    session_id, request_id
    login_name, program_name, host_name
    grant_time           — when the grant was given (NULL = still waiting)
    wait_ms              — how long it has been waiting for the grant
    requested_MB / granted_MB / used_MB
                         — requested vs actually granted vs actually used
                           if granted < requested, query is running with less
                           memory than it wants (spill to TempDB risk)
    ideal_MB             — what the optimizer calculated as ideal
    queue_id             — memory semaphore queue (large or small)
    is_small             — 1 = small grant (< 5 MB), 0 = large grant
    pool_name            — Resource Governor pool (if configured)
    semaphore_MB_total   — total available in this semaphore
    semaphore_MB_avail   — still available after all grants
    query_text           — first 200 chars of the query

  Run during a "freeze" or high-memory-pressure event.
  Also useful during SAF-T / report deep-dives.

  Inspired by sp_BlitzWho + sp_BlitzFirst (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    qmg.session_id,
    qmg.request_id,
    s.login_name,
    s.program_name,
    s.host_name,
    qmg.grant_time,
    qmg.wait_time_ms                                            AS wait_ms,

    CAST(qmg.requested_memory_kb / 1024.0 AS DECIMAL(10,1))    AS requested_MB,
    CAST(qmg.granted_memory_kb   / 1024.0 AS DECIMAL(10,1))    AS granted_MB,
    CAST(qmg.used_memory_kb      / 1024.0 AS DECIMAL(10,1))    AS used_MB,
    CAST(qmg.ideal_memory_kb     / 1024.0 AS DECIMAL(10,1))    AS ideal_MB,

    qmg.queue_id,
    qmg.is_small,
    rp.name                                                     AS pool_name,

    CAST(qrs.total_memory_kb     / 1024.0 AS DECIMAL(10,1))    AS semaphore_MB_total,
    CAST(qrs.available_memory_kb / 1024.0 AS DECIMAL(10,1))    AS semaphore_MB_avail,
    CAST(qrs.granted_memory_kb   / 1024.0 AS DECIMAL(10,1))    AS semaphore_MB_granted,

    -- Percentage of total semaphore this one grant is consuming
    CAST(
        qmg.granted_memory_kb * 100.0
        / NULLIF(qrs.total_memory_kb, 0)
    AS DECIMAL(5,1))                                            AS pct_of_semaphore,

    CAST(SUBSTRING(
        ISNULL(t.text, ''), 1, 200
    ) AS NVARCHAR(200))                                         AS query_text

FROM sys.dm_exec_query_memory_grants AS qmg

JOIN sys.dm_exec_sessions AS s
    ON qmg.session_id = s.session_id

LEFT JOIN sys.dm_exec_requests AS r
    ON  qmg.session_id  = r.session_id
    AND qmg.request_id  = r.request_id

LEFT JOIN sys.dm_exec_query_resource_semaphores AS qrs
    ON qmg.resource_semaphore_id = qrs.resource_semaphore_id

LEFT JOIN sys.resource_governor_workload_groups AS wg
    ON s.group_id = wg.group_id
LEFT JOIN sys.resource_governor_resource_pools AS rp
    ON wg.pool_id = rp.pool_id

OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t

WHERE qmg.session_id <> @@SPID

ORDER BY
    qmg.granted_memory_kb DESC,
    qmg.requested_memory_kb DESC;
