# DMV Polling Infrastructure

Continuous 15-minute DMV collection into a local SQLite database. Captures
enough high-frequency signal to see intraday patterns that cumulative DMV
queries miss (short-lived blocking chains, brief CPU spikes, peak-hour
concurrency).

## What it collects

`polling.db` (SQLite) grows these tables over time:

| Table | Contents |
|---|---|
| `poll_meta` | One row per poll — timestamp, server uptime, plan cache size |
| `procedure_stats_delta` | Per-procedure CPU/reads/execs/duration deltas since last poll |
| `active_sessions` | Currently running requests (sp_WhoIsActive-style) |
| `blocking_events` | Point-in-time captures of blocking chains |
| `wait_stats` | Cumulative wait types (for diffing) |
| `memory_clerks` | Memory consumers ranked (plan cache, buffer pool, etc.) |

Deltas are what matter — cumulative DMV stats accumulate since server restart
and don't show "what is happening right now." This poller stores snapshots
and computes deltas between them.

## Setup (macOS)

1. **Pick a base directory** for the SQLite DB + logs:
   ```bash
   mkdir -p /path/to/your-project/dmv-polling
   ```

2. **Edit `poll_dmvs.py`**: set `BASE_DIR`, `SERVER`, `USER`, `PASSWORD`,
   `DATABASE` — or set them via environment variables (recommended).

3. **Edit `poll_dmvs_wrapper.sh`**: set `PYTHON_BIN` and `SCRIPT_PATH`.

4. **Edit `launchd.plist`**: set the unique Label, absolute paths, and log
   destinations.

5. **Install the launchd agent**:
   ```bash
   cp launchd.plist ~/Library/LaunchAgents/com.yourcompany.dmvpoll.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yourcompany.dmvpoll.plist
   ```

6. **Verify it ran**:
   ```bash
   tail -f /path/to/your-project/dmv-polling/polling.log
   sqlite3 /path/to/your-project/dmv-polling/polling.db "SELECT COUNT(*) FROM poll_meta;"
   ```

## Setup (Linux — cron)

```cron
*/15 * * * * /usr/bin/python3 /path/to/polling/poll_dmvs.py >> /path/to/polling.log 2>&1
```

## Setup (Windows — Task Scheduler)

Create a scheduled task that runs `python.exe poll_dmvs.py` every 15 minutes,
"Run whether user is logged on or not", "Run with highest privileges" unchecked
(monitoring account only needs VIEW SERVER STATE on the SQL Server instance).

## Required SQL Server permissions

The monitoring login needs:
```sql
USE master;
GRANT VIEW SERVER STATE TO [monitor_user];
GRANT VIEW ANY DEFINITION TO [monitor_user];
USE [YourDatabase];
GRANT VIEW DATABASE STATE TO [monitor_user];
```

**Do not use `sa` or any sysadmin account.** A dedicated read-only user keeps
the blast radius small if credentials leak.

## Analyzing the polling.db

Use sqlite3 directly:

```sql
-- Procedures with biggest CPU burn during the polling window
SELECT
    procedure_name,
    SUM(total_worker_time_delta) / 1000000.0 AS cpu_sec_window,
    SUM(execution_count_delta)    AS execs_window
FROM procedure_stats_delta psd
JOIN poll_meta pm ON psd.poll_id = pm.poll_id
WHERE pm.poll_timestamp BETWEEN '2026-04-15' AND '2026-04-16'
GROUP BY procedure_name
ORDER BY cpu_sec_window DESC
LIMIT 20;

-- Blocking chain snapshots by size
SELECT
    pm.poll_timestamp,
    COUNT(*) AS blocked_sessions,
    MAX(wait_duration_ms) / 1000.0 AS worst_wait_sec
FROM blocking_events be
JOIN poll_meta pm ON be.poll_id = pm.poll_id
GROUP BY pm.poll_timestamp
HAVING COUNT(*) >= 3
ORDER BY pm.poll_timestamp DESC;
```

## Stopping / rotating

To stop collection:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.yourcompany.dmvpoll.plist
```

The SQLite DB grows ~5-50 MB per week depending on workload. For
multi-month engagements, archive `polling.db` weekly.
