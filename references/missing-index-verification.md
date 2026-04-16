# Missing Index Verification Methodology

Raw output from `sys.dm_db_missing_index_details` is a suggestion list, not
a deployment plan. SQL Server's DMV only sees the **read benefit** for
queries that ran — it ignores existing indexes, column types, table size,
and write cost. Deploying DMV output unchecked on a 100M+ row transactional
database routinely causes:

- Duplicate indexes on tables that already have 3+ near-identical ones
- Wide varchar(500+) payload in INCLUDE → index bigger than the base table
- Payload columns (quantities, amounts) as keys on write-heavy ledgers →
  write amplification
- Narrower existing indexes superseded by new wider ones that never get
  cleaned up → storage doubled
- Consolidation opportunities missed (4 existing indexes on same key get
  a 5th added)

## Core Principles

1. **Never execute DDL on the server during verification.** Produce a
   `.sql` file the user reviews and runs.
2. **Trust the column name, verify the column exists.** DMV output can
   reference columns that were renamed, dropped, or never existed.
3. **Read benefit is not the only cost.** Every index slows writes and
   consumes storage. Every proposal must justify both.
4. **Consolidate before adding.** If an existing index has the same key
   and narrower INCLUDE, widen the existing one (or replace it) — do not
   add a second one.
5. **Never drop an existing index in the same batch as creating its
   replacement.** Always require 7-day usage verification via
   `sys.dm_db_index_usage_stats` first.

## Workflow

### Step 1: Gather inputs

Three artefacts needed:
1. The proposed indexes (from DMV, SSMS hints, or a `.sql` draft)
2. All existing indexes on every target table
3. All column definitions on every target table

Run `queries/existing-indexes-on-tables.sql` and `queries/columns-on-tables.sql`
against the server. Save output to local text files (e.g.
`/tmp/idx_existing.txt`, `/tmp/idx_cols.txt`). Table sizes matter for risk
weighting — run `queries/table-sizes.sql` too.

### Step 2: Verify every proposed index — eight gates

For each proposed `CREATE INDEX`, run it through all eight gates before
deciding. Record the outcome before moving to the next.

#### Gate A — Column existence
Every key and INCLUDE column must exist on the target table. Miss →
`COLUMN_MISSING`, the CREATE will fail.

#### Gate B — Exact duplicate
Does an existing index have the exact same key columns in the same order
AND an exact-equal or superset INCLUDE? → `DROP — already exists`. Skip.

#### Gate C — Consolidation opportunity
Does an existing index have the exact same key in the same order but a
**narrower INCLUDE** (strict subset)? → `CONSOLIDATE`. Create new wider
index; plan a commented DROP for the old one (post-verification).

#### Gate D — Key-order variation
Same columns, different order → different query shapes. Keep, note sibling.

#### Gate E — Payload-in-key check
Is a key column a numeric/measurement type (Qtty, Amount, Price, Count,
Total)? Assess whether DMV filter-pressure justifies the write cost.

Rule of thumb:
- Low seek count (< 1000/month) and write-heavy table → move payload to
  INCLUDE. Index still covers; optimizer applies filter as residual.
- High seek count + very selective filter → key position worth it.

Write-heavy table names to watch: `*StockState*`, `*Stock*`, `*Inventory*`,
`Event`, `*Audit*`, `*Log*`, `*Movement*`, `*Transaction*`, `*Journal*`,
`*gWAC*`.

#### Gate F — Wide INCLUDE check
Any INCLUDE column varchar/nvarchar > 200 chars?

| Width on INCLUDE | Table size | Action |
|---|---|---|
| varchar(max) / varchar(5000+) | any | **REMOVE**. Never. |
| varchar(500-5000) | > 50M rows | flag, ask before keeping |
| varchar(≤100) | any | acceptable |

#### Gate G — Partial overlap
Overlaps existing roughly but not exactly → keep, tell user to monitor
`sys.dm_db_index_usage_stats`. If loser has zero seeks after 14 days, drop.

#### Gate H — Table size / tempdb risk
Tables > 100M rows:
- `ONLINE = ON, SORT_IN_TEMPDB = ON` is mandatory, not optional
- Tempdb must have ≥ 1.5× expected index size free
- Deploy in low-traffic window

### Step 3: Verification report

Present a table before rewriting the SQL file:

| # | Table | Verdict | Notes |

Verdict labels:
- `SAFE ADD`
- `DROP — already exists`
- `CONSOLIDATE` (drop old after 7d)
- `TRIM INCLUDE` (remove specific wide col)
- `FLAG — overlaps` (monitor)
- `RISKY — payload in key` (move to INCLUDE)
- `COLUMN_MISSING`

If all verdicts are straightforward `SAFE ADD`, proceed. Otherwise, confirm
with the user.

### Step 4: Deployment SQL — required structure

```sql
/*
  Header comment documenting:
    - verification date
    - deviations from DMV recommendations (and why)
    - consolidations planned
    - indexes skipped and why
    - deployment notes (tempdb, downtime window, etc.)
*/

USE [<DB>];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ============================================================================
-- #N: <TableName> — Improvement: <score>
-- Seeks: <n> | Impact: <pct>
-- Verdict: <from step 3>
-- <special notes from gates E/F/G/H>
-- ============================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = '<IdxName>' AND object_id = OBJECT_ID('<schema>.<Table>'))
CREATE NONCLUSTERED INDEX [<IdxName>]
ON [<schema>].[<Table>] (<keys>)
INCLUDE (<includes>)
WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
GO

-- ... more indexes ...

PRINT 'Creation phase complete. Verify usage for 7 days before cleanup.';
GO

/*
============================================================================
  POST-VERIFICATION CLEANUP — DO NOT RUN UNTIL 7 DAYS AFTER CREATE
  Uncomment each DROP only after confirming via dm_db_index_usage_stats
  that the new index is being used AND the old is not.
  Verification query:  queries/index-usage-verify.sql
============================================================================
*/
-- IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Old_Index' AND object_id = OBJECT_ID('dbo.Table'))
--     DROP INDEX [IX_Old_Index] ON [dbo].[Table];
```

## Script requirements

- `USE [...]` + `GO` at top
- `SET QUOTED_IDENTIFIER ON` + `SET ANSI_NULLS ON` + `GO` (required for
  filtered indexes, computed columns, and generally safer)
- `GO` after **every** CREATE — never wrap multiple CREATEs in a single
  transaction; partial success must persist
- `IF NOT EXISTS` guard on every CREATE — script is re-runnable
- `IF EXISTS` guard on every DROP — same
- Cleanup DROPs commented out by default

## Common failures

| Pattern | What usually happens | Prevention |
|---|---|---|
| DMV suggests 4 indexes on same `(SiteId, DocId)` with slightly different INCLUDEs | Deploy all 4 → huge write amplification | Consolidate into one wider (Gate C) |
| DMV puts `PropertyText varchar(5000)` in INCLUDE | Index ends up bigger than table | Trim (Gate F) |
| DMV recommends `(A, B, Qtty)` as keys on stock table | Every movement = page splits | Move payload to INCLUDE (Gate E) |
| Proposed index already exists 3× as hex-suffix duplicate | Add 4th & 5th duplicate | Exact-duplicate check (Gate B) |
| Deploy and immediately drop "old" index | New index hasn't warmed up, queries regress | 7-day gap (safety rule) |
