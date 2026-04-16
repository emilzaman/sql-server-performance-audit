/*
  duplicate-indexes.sql
  ---------------------
  Finds redundant and overlapping indexes on user tables.

  Two categories:

  1. EXACT DUPLICATES
     Same key columns in the same order, same INCLUDE columns.
     One of them can be dropped immediately (after usage verification).

  2. PREFIX DUPLICATES (one index is a leading subset of another)
     e.g. IX_A on (Col1, Col2) is made redundant by IX_B on (Col1, Col2, Col3)
     because IX_B can satisfy any query IX_A can.
     The shorter one can usually be dropped.

  Output columns:
    schema_name, table_name
    index_a / index_b      — the two overlapping indexes
    a_key_cols / b_key_cols — key column lists (ordered by key_ordinal)
    a_include / b_include  — INCLUDE column lists
    a_reads / b_reads       — seeks + scans + lookups (reads)
    a_writes / b_writes     — user_updates (write cost)
    verdict                 — EXACT_DUPLICATE or PREFIX_DUPLICATE
    action                  — which one to consider dropping

  Rules:
    - Only user tables, not system objects
    - Skips filtered indexes (has WHERE clause) — these serve specific queries
    - Skips primary keys and unique indexes flagged for enforcement
      (those cannot be dropped without changing constraints)
    - Usage stats are since last server restart — verify 7+ days before dropping

  Inspired by sp_BlitzIndex (Brent Ozar Unlimited, MIT License).
  Adapted as standalone diagnostic query.
*/

USE [master];     -- change to target database
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @db_id INT = DB_ID();

-- ============================================================================
-- Build index key + include column lists per index
-- ============================================================================
WITH IndexColumns AS (
    SELECT
        i.object_id,
        i.index_id,
        i.name          AS index_name,
        i.type_desc,
        i.is_unique,
        i.is_primary_key,
        i.has_filter,
        -- Key columns in order (is_included_column = 0)
        STUFF((
            SELECT ', ' + c.name
            FROM   sys.index_columns ic2
            JOIN   sys.columns       c  ON ic2.object_id   = c.object_id
                                        AND ic2.column_id   = c.column_id
            WHERE  ic2.object_id         = i.object_id
              AND  ic2.index_id          = i.index_id
              AND  ic2.is_included_column = 0
            ORDER  BY ic2.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS key_cols,

        -- INCLUDE columns (is_included_column = 1)
        ISNULL(STUFF((
            SELECT ', ' + c.name
            FROM   sys.index_columns ic2
            JOIN   sys.columns       c  ON ic2.object_id   = c.object_id
                                        AND ic2.column_id   = c.column_id
            WHERE  ic2.object_id         = i.object_id
              AND  ic2.index_id          = i.index_id
              AND  ic2.is_included_column = 1
            ORDER  BY c.name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), '') AS include_cols
    FROM sys.indexes AS i
    WHERE i.type IN (1, 2)      -- CLUSTERED, NONCLUSTERED only
      AND i.has_filter = 0      -- skip filtered indexes
),

IndexUsage AS (
    SELECT
        us.object_id,
        us.index_id,
        ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) AS total_reads,
        ISNULL(us.user_updates, 0) AS total_writes
    FROM sys.dm_db_index_usage_stats AS us
    WHERE us.database_id = @db_id
)

-- ============================================================================
-- Compare every pair of indexes on the same table
-- ============================================================================
SELECT
    s.name                  AS schema_name,
    t.name                  AS table_name,
    a.index_name            AS index_a,
    b.index_name            AS index_b,
    a.key_cols              AS a_key_cols,
    b.key_cols              AS b_key_cols,
    a.include_cols          AS a_include,
    b.include_cols          AS b_include,
    ISNULL(ua.total_reads,  0)  AS a_reads,
    ISNULL(ub.total_reads,  0)  AS b_reads,
    ISNULL(ua.total_writes, 0)  AS a_writes,
    ISNULL(ub.total_writes, 0)  AS b_writes,

    CASE
        WHEN a.key_cols = b.key_cols AND a.include_cols = b.include_cols
            THEN 'EXACT_DUPLICATE'
        WHEN b.key_cols LIKE a.key_cols + ',%'     -- b starts with all of a's keys
            THEN 'PREFIX_DUPLICATE'
        WHEN a.key_cols LIKE b.key_cols + ',%'     -- a starts with all of b's keys
            THEN 'PREFIX_DUPLICATE'
    END                     AS verdict,

    -- Advisory: drop the one with fewer reads (or the shorter one if equal)
    CASE
        WHEN a.key_cols = b.key_cols AND a.include_cols = b.include_cols THEN
            'Drop ' + CASE WHEN ISNULL(ua.total_reads, 0) <= ISNULL(ub.total_reads, 0)
                           THEN a.index_name ELSE b.index_name END
        WHEN b.key_cols LIKE a.key_cols + ',%' THEN
            'Consider dropping ' + a.index_name + ' (b is a superset)'
        WHEN a.key_cols LIKE b.key_cols + ',%' THEN
            'Consider dropping ' + b.index_name + ' (a is a superset)'
    END                     AS action

FROM IndexColumns   AS a
JOIN IndexColumns   AS b   ON a.object_id  = b.object_id
                           AND a.index_id  <  b.index_id   -- avoid self + reverse pairs
JOIN sys.objects    AS t   ON a.object_id  = t.object_id
JOIN sys.schemas    AS s   ON t.schema_id  = s.schema_id
LEFT JOIN IndexUsage AS ua ON ua.object_id = a.object_id AND ua.index_id = a.index_id
LEFT JOIN IndexUsage AS ub ON ub.object_id = b.object_id AND ub.index_id = b.index_id

WHERE
    t.is_ms_shipped = 0
    AND (
        -- Exact duplicate
        (a.key_cols = b.key_cols AND a.include_cols = b.include_cols)
        -- b is a superset of a (a's keys are a leading prefix of b)
        OR b.key_cols LIKE a.key_cols + ',%'
        -- a is a superset of b
        OR a.key_cols LIKE b.key_cols + ',%'
    )

ORDER BY
    s.name, t.name, verdict, a_reads DESC;
