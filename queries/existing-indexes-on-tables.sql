/*
============================================================================
  EXISTING INDEXES ON NAMED TABLES
  Use: dump all indexes on target tables with key columns and INCLUDEs.
  Required for missing-index verification (see references/missing-index-verification.md).
  Output format (pipe-delimited): IDX|<Table>|<IndexName>|<Type>|<KeyCols>|<IncCols>
  Feed target tables into @tables (comma-separated).
============================================================================
*/

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE [<<DATABASE_NAME>>];
GO

DECLARE @tables nvarchar(max) = N'Table1,Table2,Table3'; -- EDIT THIS

;WITH t AS (
    SELECT LTRIM(RTRIM(value)) AS name FROM STRING_SPLIT(@tables, ',')
),
key_cols AS (
    SELECT
        i.object_id,
        i.index_id,
        STRING_AGG(CAST(c.name AS nvarchar(max)), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS cols
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    JOIN sys.columns c        ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE ic.is_included_column = 0
    GROUP BY i.object_id, i.index_id
),
inc_cols AS (
    SELECT
        i.object_id,
        i.index_id,
        STRING_AGG(CAST(c.name AS nvarchar(max)), ',') WITHIN GROUP (ORDER BY c.name) AS cols
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    JOIN sys.columns c        ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    WHERE ic.is_included_column = 1
    GROUP BY i.object_id, i.index_id
)
SELECT
    'IDX|' + OBJECT_NAME(i.object_id)
    + '|' + i.name
    + '|' + i.type_desc
    + '|' + ISNULL(kc.cols, '')
    + '|' + ISNULL(ic.cols, 'NULL') AS line
FROM sys.indexes i
JOIN t                 ON OBJECT_NAME(i.object_id) = t.name
LEFT JOIN key_cols kc  ON i.object_id = kc.object_id AND i.index_id = kc.index_id
LEFT JOIN inc_cols ic  ON i.object_id = ic.object_id AND i.index_id = ic.index_id
WHERE i.type > 0 -- exclude heaps
ORDER BY OBJECT_NAME(i.object_id), i.index_id;
