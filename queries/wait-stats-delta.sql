/*
============================================================================
  WAIT STATS DELTA (two-snapshot diff)
  Use: cumulative wait stats are dominated by whatever was worst months ago.
  Capture a snapshot, wait N minutes, capture another, diff them — this shows
  what is waiting RIGHT NOW. Filters idle/benign waits.

  Run like this:
    1) Run first snapshot block → save output
    2) Wait 5-15 minutes
    3) Run second snapshot block → save output
    4) Diff offline (Excel / Python / SQLite join)
  Or use the polling infrastructure which automates this.
============================================================================
*/

SELECT
    GETDATE()                           AS snapshot_time,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms  AS resource_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    -- benign / idle waits to ignore
    'BROKER_EVENTHANDLER','BROKER_RECEIVE_WAITFOR','BROKER_TASK_STOP',
    'BROKER_TO_FLUSH','BROKER_TRANSMITTER','CHECKPOINT_QUEUE',
    'CHKPT','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT','DBMIRROR_EVENTS_QUEUE','DBMIRROR_WORKER_QUEUE',
    'DBMIRRORING_CMD','DIRTY_PAGE_POLL','DISPATCHER_QUEUE_SEMAPHORE',
    'EXECSYNC','FSAGENT','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'FT_IFTSHC_MUTEX','HADR_CLUSAPI_CALL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'HADR_LOGCAPTURE_WAIT','HADR_NOTIFICATION_DEQUEUE',
    'HADR_TIMER_TASK','HADR_WORK_QUEUE','KSOURCE_WAKEUP',
    'LAZYWRITER_SLEEP','LOGMGR_QUEUE','MEMORY_ALLOCATION_EXT',
    'ONDEMAND_TASK_QUEUE','PARALLEL_REDO_DRAIN_WORKER',
    'PARALLEL_REDO_LOG_CACHE','PARALLEL_REDO_TRAN_LIST',
    'PARALLEL_REDO_WORKER_SYNC','PARALLEL_REDO_WORKER_WAIT_WORK',
    'PREEMPTIVE_OS_FLUSHFILEBUFFERS','PREEMPTIVE_XE_GETTARGETSTATE',
    'PVS_PREALLOCATE','PWAIT_ALL_COMPONENTS_INITIALIZED',
    'PWAIT_DIRECTLOGCONSUMER_GETNEXT','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_SHUTDOWN_QUEUE','REDO_THREAD_PENDING_WORK',
    'REQUEST_FOR_DEADLOCK_SEARCH','RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK','SLEEP_BPOOL_FLUSH','SLEEP_DBSTARTUP',
    'SLEEP_DCOMSTARTUP','SLEEP_MASTERDBREADY','SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED','SLEEP_MSDBSTARTUP','SLEEP_SYSTEMTASK',
    'SLEEP_TASK','SLEEP_TEMPDBSTARTUP','SNI_HTTP_ACCEPT',
    'SOS_WORK_DISPATCHER','SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'SQLTRACE_WAIT_ENTRIES','WAIT_FOR_RESULTS',
    'WAITFOR','WAITFOR_TASKSHUTDOWN','WAIT_XTP_CKPT_CLOSE',
    'WAIT_XTP_HOST_WAIT','WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    'WAIT_XTP_RECOVERY','XE_BUFFERMGR_ALLPROCESSED_EVENT',
    'XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT','XE_TIMER_EVENT'
)
AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;
