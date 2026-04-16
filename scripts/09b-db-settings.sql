SET NOCOUNT ON;
SELECT
    name,
    compatibility_level,
    recovery_model_desc,
    is_auto_update_stats_on,
    is_auto_create_stats_on,
    is_auto_update_stats_async_on,
    page_verify_option_desc,
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc
FROM sys.databases
WHERE name = 'IntertoyERP';
