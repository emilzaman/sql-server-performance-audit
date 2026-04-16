# SQL Server Performance Audit

A complete, repeatable methodology for auditing large SQL Server databases — ERPs, accounting systems, high-volume OLTP. Built from a full production engagement on a 2 TB database with 12,000+ stored procedures.

## What's included

| Folder | Contents |
|---|---|
| `scripts/` | 16 baseline read-only DMV capture scripts |
| `queries/` | 10 on-demand analysis queries (plan cache, blocking, unused indexes, etc.) |
| `polling/` | 15-minute automated DMV polling (Python + launchd/cron/Task Scheduler) |
| `references/` | Deep-dive methodology docs (anti-patterns, missing-index verification, plan cache, report structure) |
| `templates/` | Fix script header template + assessment report skeleton |

## When to use this

- "The server is slow" — run Phase 1–2 to establish baseline
- You have DMV output and want analysis — jump to Phase 4 triage
- You want to verify missing-index recommendations before deploying — see `references/missing-index-verification.md`
- You want to set up ongoing monitoring — see `polling/README.md`

## Quick start

### 1. Capture baseline

```bash
sqlcmd -S <server> -U <user> -i scripts/00-master-proc-stats.sql -o reports/00-master-proc-stats.txt
sqlcmd -S <server> -U <user> -i scripts/05-wait-stats.sql        -o reports/05-wait-stats.txt
sqlcmd -S <server> -U <user> -i scripts/06-missing-indexes.sql   -o reports/06-missing-indexes.txt
```

Run all 16 scripts in `scripts/` order. Save each output to `reports/dmv-snapshots/`.

### 2. Set up continuous polling (optional)

See `polling/README.md`. Set environment variables, install the launchd plist (macOS) or cron job (Linux/Windows), and let it capture 15-minute deltas over the engagement period.

### 3. Analyze

Use `queries/` for targeted follow-up:
- `plan-cache-composition.sql` — what class is bloating the plan cache?
- `unused-indexes.sql` — what indexes can be dropped (requires 30+ days uptime)?
- `blocking-chains.sql` — live blocking investigation

### 4. Verify missing indexes

**Never deploy DMV suggestions unverified.** Follow the 8-gate methodology in `references/missing-index-verification.md` before creating any index.

### 5. Write the report

Use `templates/assessment-report.md` as the skeleton and `references/report-structure.md` as the style guide. Every finding needs: observation, evidence, impact, remediation, risk.

## Operational rules (non-negotiable)

1. **Never execute DDL on the target server.** All `ALTER`, `CREATE`, `DROP` goes into local `.sql` files the client reviews and runs.
2. **Cite specific numbers.** "Slow" is not audit language. Use cpu-sec, ms/call, MB, row counts.
3. **Never combine CREATE-new and DROP-old in the same deployment.** Always 7+ days apart, verified via `sys.dm_db_index_usage_stats`.
4. **Always generate idempotent scripts.** Every CREATE guarded by `IF NOT EXISTS`; every DROP guarded by `IF EXISTS`.
5. **`GO` after every statement** — never wrap multiple CREATEs in a single transaction.

## Anti-patterns covered

1. Scalar UDF in WHERE/SELECT on large tables
2. OUTER APPLY with TOP 1 correlated subquery
3. LEFT JOIN + WHERE on right-side column (silent INNER JOIN)
4. OPTION (FORCE ORDER) hint
5. View indirection (views calling views)
6. Unparameterized client INSERTs (Prepared-class plan cache bloat)
7. xp_userlock / sp_getapplock blocking chains
8. Nightly cursor fix-jobs papering over upstream defects
9. Wide varchar in INCLUDE columns
10. Payload columns as index keys on write-heavy tables

See `references/anti-patterns.md` for detection queries and remediation for each.

## Required SQL Server permissions (read-only monitor login)

```sql
GRANT VIEW SERVER STATE  TO [monitor_login];
GRANT VIEW ANY DEFINITION TO [monitor_login];
GRANT VIEW DATABASE STATE TO [monitor_login];
```

## Claude Code integration

This directory is structured as a Claude Code skill. Place it in `~/.agents/skills/` and symlink into `~/.claude/skills/` to make it auto-discoverable. Claude will invoke it when you say things like "audit this database", "investigate performance", or "verify these missing indexes".

## License

MIT
