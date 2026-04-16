#!/usr/bin/env python3
"""
Phase 2 DMV Polling System for MSSQL Database Assessment.

Polls key DMVs every invocation and stores raw snapshots + computed deltas
in a local SQLite database. Designed to be called every 15 minutes via launchd.
"""

import subprocess
import sqlite3
import os
import sys
import logging
import csv
import io
from datetime import datetime

# ── paths — EDIT BEFORE USE ─────────────────────────────────────────────────
# BASE_DIR: where polling.db (SQLite collector) and polling.log will live
BASE_DIR = os.environ.get("DMVPOLL_BASE_DIR", "/path/to/your/dmv-polling")
DB_PATH = os.path.join(BASE_DIR, "polling.db")
LOG_PATH = os.path.join(BASE_DIR, "polling.log")

# ── connection details — EDIT BEFORE USE ───────────────────────────────────
# Prefer reading from environment variables or a secrets file, NOT hardcoding.
# For one-off local assessments a hardcoded placeholder is fine, but do NOT
# commit real credentials into a repo.
SERVER   = os.environ.get("DMVPOLL_SERVER",   r"HOSTNAME\INSTANCE")
USER     = os.environ.get("DMVPOLL_USER",     "readonly_monitor_user")
PASSWORD = os.environ.get("DMVPOLL_PASSWORD", "CHANGE_ME")
DATABASE = os.environ.get("DMVPOLL_DATABASE", "YourDatabase")
SQLCMD_TIMEOUT = 60  # seconds

# ── logging ──────────────────────────────────────────────────────────────────
os.makedirs(BASE_DIR, exist_ok=True)

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("dmvpoll")

# ── benign / idle waits to exclude ───────────────────────────────────────────
EXCLUDED_WAITS = (
    "BROKER_EVENTHANDLER", "BROKER_RECEIVE_WAITFOR", "BROKER_TASK_STOP",
    "BROKER_TO_FLUSH", "BROKER_TRANSMITTER", "CHECKPOINT_QUEUE",
    "CHKPT", "CLR_AUTO_EVENT", "CLR_MANUAL_EVENT", "CLR_SEMAPHORE",
    "DBMIRROR_DBM_EVENT", "DBMIRROR_EVENTS_QUEUE", "DBMIRROR_WORKER_QUEUE",
    "DBMIRRORING_CMD", "DIRTY_PAGE_POLL", "DISPATCHER_QUEUE_SEMAPHORE",
    "EXECSYNC", "FSAGENT", "FT_IFTS_SCHEDULER_IDLE_WAIT",
    "FT_IFTSHC_MUTEX", "HADR_CLUSAPI_CALL", "HADR_FILESTREAM_IOMGR_IOCOMPLETION",
    "HADR_LOGCAPTURE_WAIT", "HADR_NOTIFICATION_DEQUEUE",
    "HADR_TIMER_TASK", "HADR_WORK_QUEUE", "KSOURCE_WAKEUP",
    "LAZYWRITER_SLEEP", "LOGMGR_QUEUE", "MEMORY_ALLOCATION_EXT",
    "ONDEMAND_TASK_QUEUE", "PARALLEL_REDO_DRAIN_WORKER",
    "PARALLEL_REDO_LOG_CACHE", "PARALLEL_REDO_TRAN_LIST",
    "PARALLEL_REDO_WORKER_SYNC", "PARALLEL_REDO_WORKER_WAIT_WORK",
    "PREEMPTIVE_OS_FLUSHFILEBUFFERS", "PREEMPTIVE_XE_GETTARGETSTATE",
    "PVS_PREALLOCATE", "PWAIT_ALL_COMPONENTS_INITIALIZED",
    "PWAIT_DIRECTLOGCONSUMER_GETNEXT", "QDS_PERSIST_TASK_MAIN_LOOP_SLEEP",
    "QDS_ASYNC_QUEUE", "QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP",
    "QDS_SHUTDOWN_QUEUE", "REDO_THREAD_PENDING_WORK",
    "REQUEST_FOR_DEADLOCK_SEARCH", "RESOURCE_QUEUE",
    "SERVER_IDLE_CHECK", "SLEEP_BPOOL_FLUSH", "SLEEP_DBSTARTUP",
    "SLEEP_DCOMSTARTUP", "SLEEP_MASTERDBREADY", "SLEEP_MASTERMDREADY",
    "SLEEP_MASTERUPGRADED", "SLEEP_MSDBSTARTUP", "SLEEP_SYSTEMTASK",
    "SLEEP_TASK", "SLEEP_TEMPDBSTARTUP", "SNI_HTTP_ACCEPT",
    "SOS_WORK_DISPATCHER", "SP_SERVER_DIAGNOSTICS_SLEEP",
    "SQLTRACE_BUFFER_FLUSH", "SQLTRACE_INCREMENTAL_FLUSH_SLEEP",
    "SQLTRACE_WAIT_ENTRIES", "WAIT_FOR_RESULTS",
    "WAITFOR", "WAITFOR_TASKSHUTDOWN", "WAIT_XTP_CKPT_CLOSE",
    "WAIT_XTP_HOST_WAIT", "WAIT_XTP_OFFLINE_CKPT_NEW_LOG",
    "WAIT_XTP_RECOVERY", "XE_BUFFERMGR_ALLPROCESSED_EVENT",
    "XE_DISPATCHER_JOIN", "XE_DISPATCHER_WAIT", "XE_TIMER_EVENT",
)

# ── SQL queries ──────────────────────────────────────────────────────────────
# NOTE on sqlcmd flags:
#   -W  trims trailing whitespace (good for numeric data)
#   -y 0  unlimited column width (needed for long text, but mutually exclusive with -W and -h)
#   -s "|"  column separator

SQL_PROCEDURE_STATS = r"""
SET NOCOUNT ON;
SELECT
    ps.object_id,
    OBJECT_NAME(ps.object_id, ps.database_id) AS procedure_name,
    ps.execution_count,
    ps.total_worker_time,
    ps.total_elapsed_time,
    ps.total_logical_reads,
    ps.total_physical_reads,
    ps.total_logical_writes,
    CONVERT(varchar(23), ps.last_execution_time, 121) AS last_execution_time
FROM sys.dm_exec_procedure_stats ps
WHERE ps.database_id = DB_ID()
ORDER BY ps.total_worker_time DESC;
"""

SQL_WAIT_STATS = """
SET NOCOUNT ON;
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0
  AND wait_type NOT IN ({exclusions})
ORDER BY wait_time_ms DESC;
""".format(exclusions=",".join(f"'{w}'" for w in EXCLUDED_WAITS))

SQL_BLOCKING = r"""
SET NOCOUNT ON;
SELECT
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.cpu_time,
    r.logical_reads,
    LTRIM(RTRIM(REPLACE(REPLACE(
        SUBSTRING(st.text, 1, 200),
        CHAR(10), ' '), CHAR(13), ' '))) AS sql_text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.blocking_session_id <> 0;
"""

SQL_ACTIVE_SESSIONS = r"""
SET NOCOUNT ON;
SELECT
    r.session_id,
    r.status,
    r.command,
    r.cpu_time,
    r.total_elapsed_time,
    r.logical_reads,
    r.reads,
    r.writes,
    ISNULL(r.wait_type, '') AS wait_type,
    r.wait_time,
    r.blocking_session_id,
    r.granted_query_memory * 8 / 1024 AS grant_mb,
    ISNULL(OBJECT_NAME(st.objectid, st.dbid), '') AS proc_name,
    LTRIM(RTRIM(REPLACE(REPLACE(
        SUBSTRING(st.text, (r.statement_start_offset/2)+1,
          CASE WHEN r.statement_end_offset = -1 THEN 200
               ELSE CASE WHEN (r.statement_end_offset - r.statement_start_offset)/2+1 < 200
                         THEN (r.statement_end_offset - r.statement_start_offset)/2+1
                         ELSE 200 END
          END),
        CHAR(10), ' '), CHAR(13), ' '))) AS current_stmt
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
  AND r.status <> 'background';
"""

# ── SQLite schema ────────────────────────────────────────────────────────────
SCHEMA_DDL = """
CREATE TABLE IF NOT EXISTS poll_meta (
    poll_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    poll_timestamp   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS procedure_stats (
    poll_id              INTEGER NOT NULL,
    object_id            INTEGER,
    procedure_name       TEXT,
    execution_count      INTEGER,
    total_worker_time_us INTEGER,
    total_elapsed_time_us INTEGER,
    total_logical_reads  INTEGER,
    total_physical_reads INTEGER,
    total_logical_writes INTEGER,
    last_execution_time  TEXT,
    FOREIGN KEY (poll_id) REFERENCES poll_meta(poll_id)
);

CREATE TABLE IF NOT EXISTS procedure_stats_delta (
    poll_id                INTEGER NOT NULL,
    object_id              INTEGER,
    procedure_name         TEXT,
    execution_count        INTEGER,
    total_worker_time_us   INTEGER,
    total_elapsed_time_us  INTEGER,
    total_logical_reads    INTEGER,
    total_physical_reads   INTEGER,
    total_logical_writes   INTEGER,
    last_execution_time    TEXT,
    delta_execution_count  INTEGER,
    delta_worker_time_us   INTEGER,
    delta_elapsed_time_us  INTEGER,
    delta_logical_reads    INTEGER,
    delta_physical_reads   INTEGER,
    delta_logical_writes   INTEGER,
    FOREIGN KEY (poll_id) REFERENCES poll_meta(poll_id)
);

CREATE TABLE IF NOT EXISTS wait_stats (
    poll_id              INTEGER NOT NULL,
    wait_type            TEXT,
    waiting_tasks_count  INTEGER,
    wait_time_ms         INTEGER,
    signal_wait_time_ms  INTEGER,
    FOREIGN KEY (poll_id) REFERENCES poll_meta(poll_id)
);

CREATE TABLE IF NOT EXISTS blocking_events (
    poll_id              INTEGER NOT NULL,
    session_id           INTEGER,
    blocking_session_id  INTEGER,
    wait_type            TEXT,
    wait_time            INTEGER,
    cpu_time             INTEGER,
    logical_reads        INTEGER,
    sql_text             TEXT,
    FOREIGN KEY (poll_id) REFERENCES poll_meta(poll_id)
);

CREATE TABLE IF NOT EXISTS active_sessions (
    poll_id              INTEGER NOT NULL,
    session_id           INTEGER,
    status               TEXT,
    command              TEXT,
    cpu_time             INTEGER,
    total_elapsed_time   INTEGER,
    logical_reads        INTEGER,
    physical_reads       INTEGER,
    writes               INTEGER,
    wait_type            TEXT,
    wait_time            INTEGER,
    blocking_session_id  INTEGER,
    grant_mb             INTEGER,
    proc_name            TEXT,
    current_stmt         TEXT,
    FOREIGN KEY (poll_id) REFERENCES poll_meta(poll_id)
);
"""


# ── helpers ──────────────────────────────────────────────────────────────────

def run_sqlcmd(sql: str, use_y0: bool = False) -> str | None:
    """Execute a T-SQL batch via sqlcmd and return stdout, or None on failure.

    use_y0: if True, use -y 0 alone (for text-heavy output).
            if False, use -W (for numeric output).
    """
    env = os.environ.copy()
    env["SQLCMDPASSWORD"] = PASSWORD

    cmd = [
        "sqlcmd",
        "-S", SERVER,
        "-U", USER,
        "-d", DATABASE,
        "-C",           # trust server certificate
        "-s", "|",      # column separator
    ]

    if use_y0:
        # -y 0 for unlimited column width; no -W, no -h
        cmd.extend(["-y", "0"])
    else:
        # -W trims whitespace; -h -1 removes header dashes
        cmd.extend(["-W", "-h", "-1"])

    cmd.extend(["-Q", sql])

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=SQLCMD_TIMEOUT,
            env=env,
        )
        if result.returncode != 0:
            log.error("sqlcmd failed (rc=%d): %s", result.returncode, result.stderr.strip())
            return None
        return result.stdout
    except subprocess.TimeoutExpired:
        log.error("sqlcmd timed out after %d seconds", SQLCMD_TIMEOUT)
        return None
    except FileNotFoundError:
        log.error("sqlcmd not found on PATH")
        return None
    except Exception as exc:
        log.error("Unexpected error running sqlcmd: %s", exc)
        return None


def parse_pipe_rows(raw: str, expected_cols: int) -> list[list[str]]:
    """Parse pipe-delimited sqlcmd output into rows of stripped strings.

    Skips header separator lines (---) and blank lines.
    """
    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        # skip the dashed separator row
        if set(line.replace("|", "").replace(" ", "").replace("-", "")) == set():
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < expected_cols:
            continue
        # skip header separator lines that are just dashes
        if all(set(p) <= {"-", " ", ""} for p in parts):
            continue
        rows.append(parts[:expected_cols])
    return rows


def safe_int(val: str) -> int | None:
    try:
        return int(val)
    except (ValueError, TypeError):
        return None


# ── polling functions ────────────────────────────────────────────────────────

def poll_procedure_stats(db: sqlite3.Connection, poll_id: int) -> bool:
    """Poll sys.dm_exec_procedure_stats and store raw + delta rows."""
    raw = run_sqlcmd(SQL_PROCEDURE_STATS, use_y0=True)
    if raw is None:
        log.warning("Skipping procedure_stats (query failed)")
        return False

    # First two lines are header row + dashes when using -y 0 (no -h -1)
    rows = parse_pipe_rows(raw, 9)

    # Skip the first row if it looks like a column header
    if rows and rows[0][0].strip().lower().startswith("object"):
        rows = rows[1:]

    cur = db.cursor()
    for r in rows:
        cur.execute(
            "INSERT INTO procedure_stats VALUES (?,?,?,?,?,?,?,?,?,?)",
            (
                poll_id,
                safe_int(r[0]),
                r[1],
                safe_int(r[2]),
                safe_int(r[3]),
                safe_int(r[4]),
                safe_int(r[5]),
                safe_int(r[6]),
                safe_int(r[7]),
                r[8],
            ),
        )

    # ── delta calculation ────────────────────────────────────────────────
    # Find the previous poll_id
    prev = cur.execute(
        "SELECT poll_id FROM poll_meta WHERE poll_id < ? ORDER BY poll_id DESC LIMIT 1",
        (poll_id,),
    ).fetchone()
    if prev is None:
        log.info("First poll — no delta to compute for procedure_stats")
        db.commit()
        return True

    prev_id = prev[0]
    # Current snapshot keyed by object_id
    curr_rows = cur.execute(
        "SELECT * FROM procedure_stats WHERE poll_id = ?", (poll_id,)
    ).fetchall()
    prev_rows = cur.execute(
        "SELECT * FROM procedure_stats WHERE poll_id = ?", (prev_id,)
    ).fetchall()

    prev_map = {}
    for pr in prev_rows:
        oid = pr[1]  # object_id
        if oid is not None:
            prev_map[oid] = pr

    for cr in curr_rows:
        oid = cr[1]
        if oid is None:
            continue
        pr = prev_map.get(oid)
        if pr is None:
            # New procedure — no delta
            continue

        # Compute deltas (columns: execution_count=3, worker_time=4, elapsed=5,
        # logical_reads=6, physical_reads=7, logical_writes=8)
        deltas = []
        for idx in (3, 4, 5, 6, 7, 8):
            c_val = cr[idx]
            p_val = pr[idx]
            if c_val is not None and p_val is not None:
                d = c_val - p_val
                if d < 0:
                    # Plan eviction — skip this row entirely
                    deltas = None
                    break
                deltas.append(d)
            else:
                deltas.append(None)

        if deltas is None:
            log.info("Negative delta for object_id %s — treating as fresh baseline", oid)
            continue

        cur.execute(
            "INSERT INTO procedure_stats_delta VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                poll_id, cr[1], cr[2], cr[3], cr[4], cr[5], cr[6], cr[7], cr[8], cr[9],
                deltas[0], deltas[1], deltas[2], deltas[3], deltas[4], deltas[5],
            ),
        )

    db.commit()
    log.info("procedure_stats: %d rows captured", len(rows))
    return True


def poll_wait_stats(db: sqlite3.Connection, poll_id: int) -> bool:
    """Poll sys.dm_os_wait_stats and store raw rows."""
    raw = run_sqlcmd(SQL_WAIT_STATS, use_y0=False)
    if raw is None:
        log.warning("Skipping wait_stats (query failed)")
        return False

    rows = parse_pipe_rows(raw, 4)

    cur = db.cursor()
    for r in rows:
        cur.execute(
            "INSERT INTO wait_stats VALUES (?,?,?,?,?)",
            (poll_id, r[0], safe_int(r[1]), safe_int(r[2]), safe_int(r[3])),
        )

    db.commit()
    log.info("wait_stats: %d rows captured", len(rows))
    return True


def poll_blocking(db: sqlite3.Connection, poll_id: int) -> bool:
    """Poll sys.dm_exec_requests for blocking events."""
    raw = run_sqlcmd(SQL_BLOCKING, use_y0=True)
    if raw is None:
        log.warning("Skipping blocking_events (query failed)")
        return False

    rows = parse_pipe_rows(raw, 7)
    # Skip header row if present
    if rows and rows[0][0].strip().lower().startswith("session"):
        rows = rows[1:]

    cur = db.cursor()
    for r in rows:
        cur.execute(
            "INSERT INTO blocking_events VALUES (?,?,?,?,?,?,?,?)",
            (
                poll_id,
                safe_int(r[0]),
                safe_int(r[1]),
                r[2],
                safe_int(r[3]),
                safe_int(r[4]),
                safe_int(r[5]),
                r[6],
            ),
        )

    db.commit()
    log.info("blocking_events: %d rows captured", len(rows))
    return True


def poll_active_sessions(db: sqlite3.Connection, poll_id: int) -> bool:
    """Poll all active requests (not just blocking) from sys.dm_exec_requests."""
    raw = run_sqlcmd(SQL_ACTIVE_SESSIONS, use_y0=True)
    if raw is None:
        log.warning("Skipping active_sessions (query failed)")
        return False

    rows = parse_pipe_rows(raw, 14)
    # Skip header row if present
    if rows and rows[0][0].strip().lower().startswith("session"):
        rows = rows[1:]

    cur = db.cursor()
    for r in rows:
        cur.execute(
            "INSERT INTO active_sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                poll_id,
                safe_int(r[0]),   # session_id
                r[1],             # status
                r[2],             # command
                safe_int(r[3]),   # cpu_time
                safe_int(r[4]),   # total_elapsed_time
                safe_int(r[5]),   # logical_reads
                safe_int(r[6]),   # physical_reads (reads)
                safe_int(r[7]),   # writes
                r[8],             # wait_type
                safe_int(r[9]),   # wait_time
                safe_int(r[10]),  # blocking_session_id
                safe_int(r[11]),  # grant_mb
                r[12],            # proc_name
                r[13],            # current_stmt
            ),
        )

    db.commit()
    log.info("active_sessions: %d rows captured", len(rows))
    return True


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    log.info("=== DMV poll starting ===")

    db = sqlite3.connect(DB_PATH)
    db.executescript(SCHEMA_DDL)

    # Create poll record
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    cur = db.execute("INSERT INTO poll_meta (poll_timestamp) VALUES (?)", (ts,))
    poll_id = cur.lastrowid
    db.commit()
    log.info("Poll #%d at %s", poll_id, ts)

    # Each DMV poll is independent — if one fails, try the others
    results = {}
    results["procedure_stats"] = poll_procedure_stats(db, poll_id)
    results["wait_stats"] = poll_wait_stats(db, poll_id)
    results["blocking"] = poll_blocking(db, poll_id)
    results["active_sessions"] = poll_active_sessions(db, poll_id)

    db.close()

    succeeded = sum(1 for v in results.values() if v)
    log.info("=== DMV poll complete: %d/%d succeeded ===", succeeded, len(results))

    if succeeded == 0:
        log.error("All queries failed — check VPN / connectivity")
        # Exit 0 anyway so launchd keeps scheduling future runs.
        # A transient VPN drop should not permanently disable polling.


if __name__ == "__main__":
    main()
