SET NOCOUNT ON;
-- Tempdb file space usage
SELECT
    'TEMPDB_SPACE' AS section,
    SUM(unallocated_extent_page_count) * 8 / 1024 AS free_space_mb,
    SUM(user_object_reserved_page_count) * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb,
    SUM(mixed_extent_page_count) * 8 / 1024 AS mixed_extents_mb
FROM tempdb.sys.dm_db_file_space_usage;
