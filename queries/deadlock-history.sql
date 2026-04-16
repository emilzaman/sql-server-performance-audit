/*
  deadlock-history.sql
  --------------------
  Reads deadlock graphs from the System Health Extended Events session,
  which SQL Server runs automatically and always captures deadlock XML.

  No setup required — the System Health session is always running.
  The ring buffer holds the last ~100-500 deadlock events (memory-bound).
  For longer history, point sp_BlitzLock at your XE file target instead.

  Output — one row per deadlock event:
    deadlock_time        — UTC timestamp of the deadlock
    victim_spid          — which session was chosen as the deadlock victim
    spid_1 / spid_2      — the two competing sessions
    login_1 / login_2    — logins involved
    host_1  / host_2     — host names
    app_1   / app_2      — application/program names
    wait_resource_1/2    — what each session was waiting for
    lock_mode_1/2        — lock mode requested (S, X, U, IS, IX, etc.)
    query_1 / query_2    — the SQL text of each session at deadlock time
    object_name          — table/object involved (from the resource list)

  Common deadlock patterns to look for:
    1. Same table, reverse key order (classic bookmark deadlock)
    2. Same table, different indexes (index vs clustered key)
    3. xp_userlock / sp_getapplock application locks
    4. Row vs page lock escalation during large updates

  Inspired by sp_BlitzLock (Brent Ozar Unlimited, MIT License).
  Simplified to a standalone query against the always-on System Health session.
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- Step 1: Pull raw XML from System Health ring buffer
-- ============================================================================
IF OBJECT_ID('tempdb..#deadlock_raw') IS NOT NULL DROP TABLE #deadlock_raw;

SELECT
    xdr.value('@timestamp', 'DATETIME2(3)')         AS deadlock_time,
    xdr.query('.')                                  AS deadlock_graph
INTO #deadlock_raw
FROM (
    SELECT CAST(target_data AS XML) AS ring_buffer_xml
    FROM   sys.dm_xe_sessions           AS xe_s
    JOIN   sys.dm_xe_session_targets    AS xe_t
           ON xe_s.address = xe_t.event_session_address
    WHERE  xe_s.name        = N'system_health'
      AND  xe_t.target_name = N'ring_buffer'
) AS rb
CROSS APPLY ring_buffer_xml.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS n(xdr);

-- ============================================================================
-- Step 2: Parse the deadlock graph XML into readable columns
-- ============================================================================
SELECT
    dr.deadlock_time,

    -- Victim
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/victim-list/victimProcess/@id)[1]',
        'NVARCHAR(100)')                            AS victim_process_id,

    -- Process 1
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@spid)[1]',
        'INT')                                      AS spid_1,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@loginname)[1]',
        'NVARCHAR(128)')                            AS login_1,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@hostname)[1]',
        'NVARCHAR(128)')                            AS host_1,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@clientapp)[1]',
        'NVARCHAR(256)')                            AS app_1,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@waitresource)[1]',
        'NVARCHAR(256)')                            AS wait_resource_1,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[1]/@lockMode)[1]',
        'NVARCHAR(10)')                             AS lock_mode_1,
    CAST(SUBSTRING(
        dr.deadlock_graph.value(
            '(./event/data/value/deadlock/process-list/process[1]/inputbuf)[1]',
            'NVARCHAR(MAX)'),
        1, 500) AS NVARCHAR(500))                   AS query_1,

    -- Process 2
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@spid)[1]',
        'INT')                                      AS spid_2,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@loginname)[1]',
        'NVARCHAR(128)')                            AS login_2,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@hostname)[1]',
        'NVARCHAR(128)')                            AS host_2,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@clientapp)[1]',
        'NVARCHAR(256)')                            AS app_2,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@waitresource)[1]',
        'NVARCHAR(256)')                            AS wait_resource_2,
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/process-list/process[2]/@lockMode)[1]',
        'NVARCHAR(10)')                             AS lock_mode_2,
    CAST(SUBSTRING(
        dr.deadlock_graph.value(
            '(./event/data/value/deadlock/process-list/process[2]/inputbuf)[1]',
            'NVARCHAR(MAX)'),
        1, 500) AS NVARCHAR(500))                   AS query_2,

    -- First object/resource mentioned in the resource list
    dr.deadlock_graph.value(
        '(./event/data/value/deadlock/resource-list/*[1]/@objectname)[1]',
        'NVARCHAR(256)')                            AS object_name,

    -- Full XML for detailed investigation in SSMS deadlock viewer
    dr.deadlock_graph.query(
        './event/data/value/deadlock')              AS deadlock_xml_full

FROM #deadlock_raw AS dr
ORDER BY dr.deadlock_time DESC;

DROP TABLE #deadlock_raw;
