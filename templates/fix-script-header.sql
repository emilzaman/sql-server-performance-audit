/*
============================================================================
  FIX #<NN>: <SHORT TITLE>
  Target:        <procedure name / table>
  Baseline:      <CPU / duration / I/O metric from pre-fix run>
  Expected:      <target metric after fix>
  Risk:          <LOW / MEDIUM / HIGH — what specifically could regress>
  Dependencies:  <other fixes that must go first, if any>

  Problem:
    <2-5 sentences describing root cause in plain language.>

  Change summary:
    <bulleted list of what this script does:
     - CREATE INDEX ...
     - ALTER PROCEDURE ...
     - REPLACE scalar UDF with inline set-based join
     - etc.>

  Rollback:
    <one-liner description of how to back out — e.g. 'restore procedure
     from procedures/<name>.sql in this repo'>

  Deploy during:
    <low-traffic window requirement, if any; ONLINE or not>
============================================================================
*/

USE [<<DATABASE_NAME>>];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ============================================================================
-- Pre-deploy safety check (optional — uncomment if needed)
-- ============================================================================
-- IF EXISTS (SELECT 1 FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
-- BEGIN
--     RAISERROR('Blocking chain detected — aborting deploy.', 16, 1);
--     RETURN;
-- END

-- ============================================================================
-- Change block
-- ============================================================================

-- <your CREATE / ALTER statements here, one per GO batch>

GO

-- ============================================================================
-- Post-deploy verification
-- ============================================================================
PRINT 'Fix #<NN> deployed. Verify with:';
PRINT '  <verification query or stored proc test call>';
GO
