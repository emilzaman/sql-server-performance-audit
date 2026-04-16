# Plan Cache Analysis

The plan cache is where SQL Server stores compiled query plans. A healthy
cache is small, stable, and reused heavily. A bloated cache wastes RAM that
should be going to the buffer pool.

## When to investigate

- Users report slow performance that improves after a restart (temporary fix)
- `DBCC MEMORYSTATUS` shows plan cache consuming > 15% of `max server memory`
- Buffer pool cache hit ratio is lower than expected for DB size
- You see COMPILE / RECOMPILE waits in wait stats

## Three cache classes — they behave very differently

Query with `queries/plan-cache-composition.sql`:

| Class | What it holds | Fix if bloated |
|---|---|---|
| **Proc** | `sys.procedures` and friends | Unusual to be bloated; check for `sp_executesql` abuse |
| **Adhoc** | Raw ad-hoc SQL (no parameters) | `sp_configure 'optimize for ad hoc workloads', 1` stores only a stub for single-use plans |
| **Prepared** | Parameterized SQL sent by clients (`sp_prepare`, ORMs) | Setting above does NOT help — you need database-level parameterization or client-side fix |

**Do not reflexively recommend "Optimize for Ad Hoc Workloads"** — it's
often the wrong answer. Check which class is actually bloated first.

## Single-use bloat — the real enemy

Each cached plan has a `usecounts`. Plans with `usecounts = 1` are compiled
and never reused. On a busy ERP that's hundreds of MB to multiple GB of
waste.

Detection:
```sql
SELECT objtype, COUNT(*) AS plans,
       SUM(CAST(size_in_bytes AS bigint)) / 1024 / 1024 AS total_mb,
       SUM(CASE WHEN usecounts = 1
                THEN CAST(size_in_bytes AS bigint) ELSE 0 END) / 1024 / 1024 AS single_use_mb
FROM sys.dm_exec_cached_plans
GROUP BY objtype;
```

## Identifying the offender statements

For Prepared bloat (the common case on ORMs and legacy ERPs), use
`queries/plan-cache-top-offenders.sql`. It returns the first 300 chars of
each statement's cached text, grouped and counted. Look for:

- One INSERT statement with 10,000+ duplicate plans → unparameterized values
- The same UPDATE with 100s of duplicates that differ only in literal IDs
- Queries that embed `@P1 nvarchar(10)`, `@P2 nvarchar(11)`, `@P3 nvarchar(12)`...
  (parameter sized to actual string length, not a fixed width)

## Root causes

### Client-side unparameterized INSERTs
Typical ORM generates:
```sql
INSERT INTO [dbo].[Table] (col1, col2, ...)
VALUES (123, 'abc', GETDATE(), @P1, @P2);
```
where `123` and `'abc'` are literals, only a few values are parameters.
Every distinct literal combination = a new plan.

**Fix priority**:
1. (Best) Vendor fix — ORM sends all values as parameters with fixed types
2. (Workaround) `ALTER DATABASE ... SET PARAMETERIZATION FORCED` — auto-
   parameterizes all literals at the DB level
3. (Last resort) Plan guides for specific statements

### Parameter-sized string types
`nvarchar(10)`, `nvarchar(11)`, `nvarchar(12)` — these are three different
plans even though they could use the same one. Client should always pass
`nvarchar(256)` or the column's actual declared size.

### Option-level changes per connection
`SET ARITHABORT`, `SET QUOTED_IDENTIFIER`, `SET ANSI_NULLS` — if the
application and SSMS send different SET options, you get separate plans for
the same statement. Check `sys.dm_exec_plan_attributes` for `set_options`.

## Testing FORCED parameterization safely

Never flip on prod first. Sequence:
1. Restore a recent backup to a staging server
2. Replay a known-heavy procedure set (use Profiler / Extended Events capture)
3. Check:
   - Plan cache size after the replay (should drop significantly)
   - Plan count for top offenders (should collapse to 1-2 plans each)
   - Query performance on queries that used literal-value optimization
     (e.g., `WHERE Col = 0` where 0 enables a filtered index seek)
4. If any query regresses significantly, prepare plan guides to pin the
   literal plan for those specific statements
5. Deploy with a rollback plan: `ALTER DATABASE ... SET PARAMETERIZATION SIMPLE`

## Expected impact when successful

- Plan cache shrinks 50-90% (freed RAM goes to buffer pool)
- Compilation CPU drops significantly
- `CMEMTHREAD` / `SOS_CACHESTORE_SPINLOCK` waits drop
- Document-save / record-insert latency improves (less compile time)

## What it will NOT fix

- Slow queries that are slow due to missing indexes
- Scalar UDFs that block inlining
- Bad plans caused by parameter sniffing (PLE / forcing / `OPTIMIZE FOR`
  hints are the right tools for that)
