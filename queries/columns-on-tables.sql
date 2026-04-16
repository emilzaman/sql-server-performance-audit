/*
============================================================================
  COLUMNS ON NAMED TABLES — name and type
  Use: cross-reference proposed index columns against actual schema.
  Output format: <TableName>|<ColumnName>|<TypeWithLength>
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
)
SELECT
    OBJECT_NAME(c.object_id)
    + '|' + c.name
    + '|' + tp.name
    + CASE
        WHEN tp.name IN ('varchar','nvarchar','char','nchar','varbinary')
            THEN '(' + CASE WHEN c.max_length = -1 THEN 'max'
                            WHEN tp.name IN ('nvarchar','nchar')
                                THEN CAST(c.max_length/2 AS varchar(10))
                            ELSE CAST(c.max_length AS varchar(10))
                       END + ')'
        WHEN tp.name IN ('decimal','numeric')
            THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')'
        ELSE ''
      END AS line
FROM sys.columns c
JOIN sys.types   tp ON c.user_type_id = tp.user_type_id
JOIN t              ON OBJECT_NAME(c.object_id) = t.name
ORDER BY OBJECT_NAME(c.object_id), c.column_id;
