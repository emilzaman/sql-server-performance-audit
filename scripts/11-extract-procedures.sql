-- 11-extract-procedures.sql
-- READ-ONLY. Prints the full source of one stored procedure, function, view or
-- trigger so it can be read before any recommendation (Phase 5). Changes nothing.
--
-- Run it in the target database, one object per run:
--   sqlcmd -S <server> -U <user> -d <database> -y 0 -h -1 \
--          -v ObjectName="dbo.usp_Example" \
--          -i scripts/11-extract-procedures.sql -o procedures/usp_Example.sql
--
-- -y 0 stops sqlcmd truncating long text; -h -1 drops the column header.
-- Needs VIEW DEFINITION on the object (VIEW ANY DEFINITION covers it).
-- Encrypted modules return NULL: report that instead of guessing the code.
SET NOCOUNT ON;

DECLARE @name sysname = N'$(ObjectName)';
DECLARE @db   sysname = DB_NAME();
DECLARE @id   int     = OBJECT_ID(@name);

IF @id IS NULL
    RAISERROR(N'Object %s not found in database %s (check the schema prefix and -d).', 16, 1, @name, @db);
ELSE IF OBJECT_DEFINITION(@id) IS NULL
    RAISERROR(N'Object %s has no readable definition (encrypted, or missing VIEW DEFINITION).', 16, 1, @name);
ELSE
    SELECT OBJECT_DEFINITION(@id);
