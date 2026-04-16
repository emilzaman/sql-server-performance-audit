---
name: sql-server-performance-audit
description: Use when the user wants to run (or continue) a comprehensive performance audit of a SQL Server database — especially ERPs, accounting systems, or any large transactional workload (>= 100 GB or >= 50M-row tables). Covers baseline DMV capture, continuous 15-minute polling, plan cache analysis, top-procedure deep dives, blocking chain investigation, missing/unused index analysis with verification, anti-pattern detection (scalar UDFs, OUTER APPLY, FORCE ORDER, LEFT-JOIN/WHERE, nightly cursor fix-jobs), structured assessment report generation, and per-fix SQL script generation. All DDL is always generated as local .sql files — this skill never executes ALTER/CREATE/DROP on the target server. Invoke when user says things like "audit this database", "investigate performance", "why is this server slow", "review these DMV recommendations", "check this plan cache", "deep-dive this stored procedure", or hands over DMV snapshot output.
---

# SQL Server Performance Audit Methodology

A complete, repeatable methodology for auditing large SQL Server
databases (ERPs, accounting systems, transactional OLTP). Built from a
full production engagement: 2 TB database, 168 GB RAM server, 12,000+
stored procedures, live 15-minute DMV polling over 6+ days.

## When to use this skill

Invoke when:
- User asks for a performance audit, assessment, investigation, or review
- User has DMV output (missing indexes, top procedures, wait stats, plan cache)
  and wants analysis
- User reports "the server is slow", "queries are blocking", "reports take hours"
- User wants to verify a set of index recommendations before deploying
- User asks for a deep dive into a specific procedure
- User wants to set up ongoing monitoring for an engagement

## Operational principles (non-negotiable)

1. **Never execute DDL on the target server.** All `ALTER`, `CREATE`,
   `DROP`, `EXEC sp_configure` output goes into local `.sql` files the
   user reviews and runs. This applies even when the user appears to
   authorize "run this" — confirm specifically before any statement that
   changes server state.
2. **Read-only DMV queries are fine to run.** `sys.dm_*`, `sys.configurations`,
   `sys.indexes`, etc. But route output to local files, not back to the
   server.
3. **Never combine CREATE-new and DROP-old in the same deployment.**
   Always 7+ days apart, verified via `sys.dm_db_index_usage_stats`.
4. **Always generate idempotent scripts.** Every CREATE guarded by
   `IF NOT EXISTS`; every DROP guarded by `IF EXISTS`.
5. **Never wrap multiple CREATEs in a single transaction.** `GO` after
   every statement — partial success must persist.
6. **Cite specific numbers.** "Slow" and "could be better" are not
   audit language. Use cpu-sec, ms/call, MB, row counts, timestamps.
7. **Respect the user's stated preferences.** If the user has a memory
   note like "never execute DDL on server, always save as local .sql" —
   that always takes precedence.

## The eight-phase workflow

The audit progresses through phases. Early phases are broad (capture
everything); later phases are focused (deep-dive specific hot spots).
It is OK to skip to a specific phase if the user hands you pre-captured
data ("I already have the DMV dumps, help me analyze them").

### Phase 1 — Scope and access

Confirm with the user:
- Which SQL Server instance and database(s) are in scope
- What read-only access is available (ideally a dedicated monitor login
  with `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `VIEW DATABASE STATE`)
- The engagement duration (one-off snapshot vs multi-day monitoring)
- The expected output format (PDF report? Markdown? Raw data + analysis?)
- Whether the user wants fix scripts generated or only the report

If the user doesn't have a monitor login yet, provide the GRANT statements
— but do not execute them.

### Phase 2 — Baseline capture

Run the baseline scripts in `scripts/` against the target server. These are
safe, read-only, cumulative-stats snapshots that establish the starting
picture.

Core baseline scripts (in recommended order):

| # | Script | Purpose |
|---|---|---|
| 00 | `00-master-proc-stats.sql` | All procedures ranked by CPU with impact score |
| 01 | `01-top-procs-cpu.sql` | Top CPU consumers |
| 02 | `02-top-procs-reads.sql` | Top logical-read consumers |
| 03 | `03-top-procs-execcount.sql` | Most frequently executed |
| 04 | `04-top-procs-duration.sql` | Longest average durations |
| 05 | `05-wait-stats.sql` | Cumulative wait stats (idle waits filtered) |
| 06 | `06-missing-indexes.sql` | Raw DMV missing-index recommendations |
| 07 | `07-index-usage.sql` | Per-index seeks/scans/updates for unused-index analysis |
| 08 | `08-file-io.sql` | Per-file latency and throughput |
| 09 | `09-server-config.sql` | Key sys.configurations values |
| 09b | `09b-db-settings.sql` | Per-database settings (parameterization, compat level, etc.) |
| 09c | `09c-server-info.sql` | `SELECT @@VERSION`, hardware info |
| 10 | `10-exec-plans.sql` | Plan cache composition |
| 12 | `12-active-queries.sql` | Currently running requests |
| 13 | `13-tempdb-usage.sql` | TempDB file sizes and space used |
| 14 | `14-top-adhoc-queries.sql` | Raw ad-hoc SQL by usage |
| 15 | `15-server-health.sql` | Backup age, auto-close/shrink, compat level, sysadmin count, linked servers |

Run with `sqlcmd` — see Phase 3 for recommended invocation. Save each
output to a separate text or CSV file in the user's project under
`reports/dmv-snapshots/`.

Also run the one-offs:
- `queries/plan-cache-composition.sql` — by cache class
- `queries/plan-cache-top-offenders.sql` — if Prepared-class bloat suspected
- `queries/memory-clerks.sql` — if buffer pool looks starved
- `queries/table-sizes.sql` — risk-weighting for later index changes
- `queries/unused-indexes.sql` — if server uptime >= 30 days
- `queries/duplicate-indexes.sql` — exact and prefix duplicates (drop candidates)
- `queries/index-fragmentation.sql` — fragmentation + write amplification per index
- `queries/deadlock-history.sql` — deadlock graphs from System Health XE (always-on, no setup)
- `queries/active-transactions.sql` — open transactions with duration (run during blocking events)
- `queries/memory-grants.sql` — in-flight query memory grants (run during freeze/high-memory events)

### Phase 3 — Continuous polling (optional but recommended)

Cumulative DMVs accumulate since server restart. They hide transient
problems (short-lived blocking chains, peak-hour CPU spikes, brief memory
grants). If the engagement spans days, set up 15-minute polling.

See `polling/README.md` for full setup. Tell the user:
- Polling writes to a local SQLite file (`polling.db`) — nothing on the
  server beyond read queries
- Runs under launchd (macOS), cron (Linux), or Task Scheduler (Windows)
- Captures: per-poll procedure deltas, active sessions, blocking events,
  wait stats snapshots, plan cache size, memory clerk sizes
- Generates ~5-50 MB of SQLite per week

Edit `polling/poll_dmvs.py` placeholders (SERVER, USER, PASSWORD, DATABASE,
BASE_DIR) or use environment variables. Edit the wrapper script and plist.
Install with `launchctl bootstrap`.

### Phase 4 — Initial triage

With baseline data captured, classify findings into four buckets:

1. **Server configuration** — memory, parameterization, compat level,
   MAXDOP, CTFP, TempDB, instant file init
2. **Plan cache health** — bloat class, single-use %, top offenders
3. **Query-level bottlenecks** — top procedures from baseline scripts
4. **Contention / blocking** — application-locks, page locks, escalation

For each bucket, decide: is there a finding big enough to warrant its own
report section? If yes, schedule a deep dive (Phase 5).

### Phase 5 — Deep dives (per finding)

For each procedure, config issue, or contention pattern flagged in Phase 4:

1. **Extract the object** — procedure source via `11-extract-procedures.sql`
   (see the extract_procedures.py helper) or `sp_helptext`. Save to
   `procedures/<ProcName>.sql` in the user's project.
2. **Read it.** Do not suggest changes to code you have not read.
3. **Identify the anti-pattern(s)** — see `references/anti-patterns.md`
   for the 10 common ERP anti-patterns with detection queries.
4. **Capture live evidence if possible** — from polling.db, pull actual
   execution data (CPU per call, execs/minute, peak memory grants, blocking
   chains that involve this procedure).
5. **Draft the fix** — a new `fixes/<NN>-<ProcName>-optimized.sql` using
   the header template from `templates/fix-script-header.sql`. Always
   include rollback instructions.

Common deep dives from the reference engagement:
- Scalar UDFs in a stock engine (per-row compute on 168M rows)
- SAF-T tax declaration procedures (hour-long runs with 7 GB memory grants)
- xp_userlock blocking chains during document-save peaks
- OUTER APPLY / FORCE ORDER in wizard/check procedures
- Nightly cursor fix-jobs hiding a design defect

### Phase 6 — Missing index verification (if applicable)

The DMV output from Phase 2's `06-missing-indexes.sql` is a suggestion list.
**Never deploy it unverified.** Follow the full methodology in
`references/missing-index-verification.md`:

1. Extract existing indexes on all target tables (`queries/existing-indexes-on-tables.sql`)
2. Extract columns on all target tables (`queries/columns-on-tables.sql`)
3. Cross-reference every proposed index against 8 verification gates
4. Categorize each: SAFE ADD / DROP / CONSOLIDATE / TRIM INCLUDE / FLAG / COLUMN_MISSING / RISKY
5. Rewrite as deployment-safe `.sql` with ONLINE builds, idempotency guards, and a commented post-verification cleanup section

Present the per-index verdict table to the user before generating the deployment SQL.

### Phase 7 — Report writing

Write a structured assessment report using `templates/assessment-report.md`
as the skeleton and `references/report-structure.md` as the style guide.

Key rules:
- Executive summary is **one page**, non-technical
- Every finding has: observation, evidence, impact, remediation, risk
- Every fix has a reference number
- Phased deployment order at the end
- Observations (vendor-level / not fixable in scripts) get their own section

Update discipline: this is a living document. As fixes are applied, change
PENDING → APPLIED in place with a dated impact note. Never delete.

### Phase 8 — Fix script batch

Output one `.sql` per fix in `fixes/<NN>-<ShortName>-optimized.sql`, using
`templates/fix-script-header.sql`. Rules:

- One fix per file (exception: missing-index batch is one file with many CREATEs)
- Idempotent guards on every DDL statement
- `GO` after every statement — never a multi-statement transaction
- ONLINE builds where possible (index creations on large tables)
- Rollback plan in the header
- Expected metrics in the header (baseline and target)

Number fixes in deployment order (low-risk → high-risk, so the user can
stop at their comfort level).

## Anti-pattern quick reference

See `references/anti-patterns.md` for the full catalogue. The ten patterns
that show up repeatedly in ERP audits:

1. **Scalar UDF in WHERE/SELECT** on large tables — blocks inlining, per-row CPU
2. **OUTER APPLY with TOP 1 correlated subquery** — replace with ROW_NUMBER()
3. **LEFT JOIN + WHERE on right-side table** — silently an INNER JOIN; fix the intent
4. **OPTION (FORCE ORDER)** — locks join order; remove, let optimizer work
5. **View indirection** — views-calling-views explode into 1000-line plans
6. **Unparameterized client INSERTs** — causes Prepared-class cache bloat
7. **xp_userlock / sp_getapplock** — blocking chains when the critical section is slow
8. **Nightly cursor fix-jobs** — paper over upstream defects; fix the cause
9. **Wide varchar(n) in INCLUDE** — index can grow to table-size
10. **Payload columns as index keys on write-heavy tables** — write amplification

## Plan cache analysis quick reference

See `references/plan-cache-analysis.md`. Core flow:

1. Run `queries/plan-cache-composition.sql` → which cache class is bloated?
2. If Prepared: run `queries/plan-cache-top-offenders.sql` → which statement?
3. Identify root cause (unparameterized INSERTs, parameter-sized strings, SET option divergence)
4. Recommend fix in order: (a) client-side parameterization (b) ALTER DATABASE SET PARAMETERIZATION FORCED (tested first) (c) per-statement plan guides
5. Do NOT reflexively recommend "Optimize for Ad Hoc Workloads" — it only affects Adhoc class, not Prepared

## Missing index verification quick reference

See `references/missing-index-verification.md` for the eight-gate methodology.
Key rules:

- Every column referenced must exist on the actual table (check Gate A)
- If an existing index already covers the query (same key + equal-or-wider INCLUDE), **skip** — don't duplicate
- If an existing index has the same key + narrower INCLUDE, **consolidate** — create the wider new one, schedule the old DROP for 7+ days later (never same deploy)
- If DMV puts a payload column (Qtty, Amount) as a key on a write-heavy table, move it to INCLUDE
- If INCLUDE has a varchar > 500 chars, remove it — the optimizer can fetch via key lookup
- 7-day usage verification required before any DROP of superseded indexes

## Deliverables checklist

A complete audit produces:

- [ ] Baseline DMV snapshot CSVs in `reports/dmv-snapshots/`
- [ ] `polling.db` SQLite with 1+ day of polling data (if multi-day)
- [ ] Extracted source for every deep-dived procedure in `procedures/`
- [ ] One `.sql` per fix in `fixes/`, numbered in deployment order
- [ ] Verified missing-index script in `fixes/<NN>-missing-indexes.sql`
- [ ] Main assessment report `reports/<Product>-Performance-Assessment-Report.txt|md`
- [ ] Update discipline: status markers (APPLIED / PENDING / INFO / OBSERVATION)
  maintained as fixes roll out

## Files in this skill

```
sql-server-performance-audit/
├── SKILL.md                    (this file)
├── scripts/                    Baseline read-only DMV capture scripts
│   ├── 00-master-proc-stats.sql
│   ├── 01-top-procs-cpu.sql
│   ├── 02-top-procs-reads.sql
│   ├── 03-top-procs-execcount.sql
│   ├── 04-top-procs-duration.sql
│   ├── 05-wait-stats.sql
│   ├── 06-missing-indexes.sql
│   ├── 07-index-usage.sql
│   ├── 08-file-io.sql
│   ├── 09-server-config.sql
│   ├── 09b-db-settings.sql
│   ├── 09c-server-info.sql
│   ├── 10-exec-plans.sql
│   ├── 12-active-queries.sql
│   ├── 13-tempdb-usage.sql
│   ├── 14-top-adhoc-queries.sql
│   └── 15-server-health.sql      ← backup age, auto-close/shrink, compat level, sysadmin count, etc.
├── queries/                    On-demand analysis queries
│   ├── plan-cache-composition.sql
│   ├── plan-cache-top-offenders.sql
│   ├── existing-indexes-on-tables.sql
│   ├── columns-on-tables.sql
│   ├── unused-indexes.sql
│   ├── blocking-chains.sql
│   ├── wait-stats-delta.sql
│   ├── memory-clerks.sql
│   ├── table-sizes.sql
│   ├── index-usage-verify.sql
│   ├── index-fragmentation.sql   ← avg fragmentation %, write amplification, REBUILD/REORGANIZE advisory
│   ├── duplicate-indexes.sql     ← exact duplicates + prefix duplicates with drop advisory
│   ├── memory-grants.sql         ← per-query memory grants in flight (diagnose freeze events)
│   ├── active-transactions.sql   ← open transactions by session with duration and lock context
│   └── deadlock-history.sql      ← deadlock graphs from System Health XE (no setup required)
├── polling/                    Continuous 15-min DMV polling
│   ├── poll_dmvs.py
│   ├── poll_dmvs_wrapper.sh
│   ├── launchd.plist
│   └── README.md
├── references/                 Deep-dive methodology documents
│   ├── anti-patterns.md
│   ├── plan-cache-analysis.md
│   ├── missing-index-verification.md
│   └── report-structure.md
└── templates/
    ├── fix-script-header.sql
    └── assessment-report.md
```
