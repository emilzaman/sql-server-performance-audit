# Common SQL Server Anti-Patterns (ERP-Heavy)

These are the recurring design/query patterns that show up as CPU or I/O
leaders in ERP workloads. Each has a detection query, a root-cause
explanation, and a standard remediation.

---

## 1. Scalar UDF in WHERE / SELECT on large tables

**Symptom**: procedure's execution plan shows a Compute Scalar operator on
every row of a 100M+ row table; CPU spikes with low wait time. Query may run
single-threaded regardless of MAXDOP.

**Detection**:
```sql
SELECT
    OBJECT_NAME(m.object_id)                           AS caller,
    OBJECT_NAME(d.referenced_id)                       AS called_udf,
    o.type_desc
FROM sys.sql_expression_dependencies d
JOIN sys.sql_modules   m ON d.referencing_id = m.object_id
JOIN sys.objects       o ON d.referenced_id  = o.object_id
WHERE o.type IN ('FN','IF','TF')                       -- scalar/inline/table-valued
  AND OBJECT_NAME(m.object_id) = 'ProcedureNameToAudit';
```

**Why it hurts**: SQL Server 2019+ inlines *some* scalar UDFs but only the
ones that meet strict criteria (no time-dependent functions, no EXEC, no
cursors, etc.). When inlining is blocked the UDF executes once per row,
switching to a per-row context — catastrophic on a 168M-row stock ledger.

**Remediation (in order of preference)**:
1. Rewrite the UDF as an INLINE TVF (`RETURN ( SELECT ... )` — no BEGIN/END)
2. Convert the calling query to use set-based joins instead of calling the UDF
3. If neither is possible, check `sys.sql_modules.is_inlineable = 1` on SQL 2019+

**Real example**: `WIZ_CheckSavedTransaction2` called `fnAccountancyCheck` on
each DocumentDetail row; replacing with a LEFT JOIN onto the equivalent
projection dropped CPU by 90%.

---

## 2. OUTER APPLY with correlated subquery in SELECT list

**Symptom**: "subquery in the SELECT clause" — usually written by developers
who wanted a "scalar" result column but chose APPLY for flexibility.

**Detection**: grep procedure bodies for `OUTER APPLY (SELECT TOP 1 ...)`.

**Why it hurts**: the optimizer cannot always flatten this into a join; in
large-result queries it executes the APPLY per outer row.

**Remediation**:
```sql
-- BEFORE (runs subquery per row)
SELECT d.*, oa.LastPaymentDate
FROM Document d
OUTER APPLY (
    SELECT TOP 1 p.PaymentDate AS LastPaymentDate
    FROM Payment p
    WHERE p.DocumentId = d.DocumentId
    ORDER BY p.PaymentDate DESC
) oa;

-- AFTER (set-based ROW_NUMBER — one pass)
WITH latest_payment AS (
    SELECT
        DocumentId,
        PaymentDate,
        ROW_NUMBER() OVER (PARTITION BY DocumentId ORDER BY PaymentDate DESC) AS rn
    FROM Payment
)
SELECT d.*, lp.PaymentDate AS LastPaymentDate
FROM Document d
LEFT JOIN latest_payment lp ON lp.DocumentId = d.DocumentId AND lp.rn = 1;
```

---

## 3. LEFT JOIN with WHERE on the right-side table

**Symptom**: developer writes `LEFT JOIN B ON ...` then filters `WHERE B.col = X`
in the WHERE clause.

**Why it hurts**: the WHERE filter converts the LEFT JOIN into an INNER JOIN
silently — the optimizer may reorder, but it's non-obvious to readers and
often the original "LEFT" intent was wrong anyway. When combined with
FORCE ORDER (pattern #4), it locks in a bad join order.

**Remediation**: if you really need the filter, use INNER JOIN and say so.
If you want to preserve rows from the left side, move the filter into the
ON clause:
```sql
LEFT JOIN B ON A.id = B.a_id AND B.col = X
```

---

## 4. OPTION (FORCE ORDER) hints

**Symptom**: procedure has `OPTION (FORCE ORDER)` at the end.

**Why it hurts**: locks the join order to the written order, preventing the
optimizer from picking a better one as data volumes grow. What was fast at
1M rows can be 100× slower at 100M rows.

**Remediation**: remove the hint and verify the plan. If the removal
regresses, use a Query Store plan forcing or plan guide for that specific
query instead of the blunt hint. Never leave FORCE ORDER in new code.

**Real example**: 29 instances across 4 SAF-T procedures; removing them
allowed the optimizer to switch from nested loops to hash joins on 100M+ row
tables, dropping runtime from 4 hours to under 1 hour.

---

## 5. View indirection (views calling views calling views)

**Symptom**: a "simple-looking" SELECT against `vwSomething` expands into a
1000-line plan because the view joins 7 other views.

**Detection**:
```sql
SELECT
    v.name AS view_name,
    COUNT(DISTINCT d.referenced_id) AS dependencies
FROM sys.views v
JOIN sys.sql_expression_dependencies d ON d.referencing_id = v.object_id
GROUP BY v.name
ORDER BY dependencies DESC;
```

**Remediation**: inline the view's logic into the procedure where
performance matters. Views are a documentation/encapsulation tool, not a
performance feature.

---

## 6. Unparameterized client INSERTs (plan cache bloat)

**Symptom**: `sys.dm_exec_cached_plans` shows tens of thousands of `Prepared`
plans with `usecounts = 1`, all structurally similar INSERTs on the same
table. See `queries/plan-cache-top-offenders.sql`.

**Why it hurts**:
- Every INSERT compiles a new plan (~1-50ms CPU) instead of reusing one
- Plan cache bloats; buffer pool evicts data pages to make room
- Compilation locks (COMPILE waits) block other queries

**Remediation (in order of preference)**:
1. **Client-side fix** (correct): application must send all values as
   parameters with consistent types. Escalate to the vendor.
2. **Database-level FORCED parameterization** (server-side workaround):
   ```sql
   ALTER DATABASE [YourDB] SET PARAMETERIZATION FORCED;
   ```
   Auto-parameterizes ALL literals — fixes the bloat but can change plans
   for queries that depended on literal-value optimization. **Test in
   non-production first.**
3. **Plan guides** for specific offender statements — lower risk, higher
   maintenance cost.

---

## 7. xp_userlock application locks (SPID embedding)

**Symptom**: blocking chains where the wait resource is `APPLICATION:...`
with the SPID embedded in the lock name.

**Detection**:
```sql
SELECT
    resource_description,
    COUNT(*) AS waiters
FROM sys.dm_tran_locks
WHERE resource_type = 'APPLICATION'
GROUP BY resource_description
HAVING COUNT(*) > 1;
```

**Why it hurts**: some ERP procedures use `sp_getapplock` with a SPID-derived
key to serialize document saves. When the inner save is slow (often due to
anti-patterns #1 and #4), all concurrent users queue on the app lock.

**Remediation**: identify the slow inner procedure (usually a `Check*` proc)
and optimize it. The app lock itself is usually appropriate; the problem is
that the critical section is too slow.

---

## 8. Nightly maintenance cursors papering over bugs

**Symptom**: a procedure that does `DECLARE cursor FOR ... WHILE @@fetch_status = 0
... EXEC per-row-proc ...` on thousands of rows, scheduled nightly.

**Red flag indicators**:
- Name contains "Correction", "Fix", "Repair", "Sync", "Recalc", "_Corectie"
- Contains multiple `#temp` tables each defining a different "inconsistency"
- Calls a per-row fix procedure in a cursor

**Why it hurts**:
- Treats symptoms, not root cause — data keeps drifting, job runs forever
- Cursor overhead on large result sets burns CPU
- Can run for hours and block other maintenance windows

**Remediation**:
1. Identify **what causes** the inconsistency in the first place (usually
   a missing trigger, a broken save path, or a race condition)
2. Fix the root cause
3. Reduce the maintenance job to weekly once backlog is cleared
4. Eventually remove it entirely

**Real example**: `_USP_PartInvoiceEvents` ran 74 minutes nightly processing
thousands of inconsistent invoice payment states. Root cause was missing
post-payment trigger logic; the "fix" job was papering over a design gap.

---

## 9. Wide varchar(n) in INCLUDE on large indexes

**Symptom**: index size is suspiciously close to base table size.

**Why it hurts**: every INCLUDE column is stored at the leaf level per row.
A `varchar(5000)` INCLUDE on a 100M-row table can be ~500 GB.

**Remediation**: never INCLUDE varchars longer than ~200 chars. If a query
truly needs a wide varchar covered, reconsider whether a key lookup is
actually expensive enough to justify the storage.

---

## 10. Payload columns as index keys on write-heavy tables

**Symptom**: DMV suggests an index with a quantity/amount column as a key.

**Why it hurts**: the index must maintain sort order on the key column on
every write. For a stock ledger where Qtty changes constantly, this is
expensive.

**Remediation**: move payload to INCLUDE. The index still covers; the
optimizer applies filters as residuals at the leaf level. Only keep payload
in key if the query seeks on a very selective predicate AND the seek count
justifies the write cost.

See `references/missing-index-verification.md` for the full workflow.
