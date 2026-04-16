SET NOCOUNT ON;
-- Server configuration
SELECT
    'CONFIG' AS section,
    name,
    CAST(value AS VARCHAR(50)) AS value,
    CAST(value_in_use AS VARCHAR(50)) AS value_in_use,
    CAST(minimum AS VARCHAR(50)) AS minimum,
    CAST(maximum AS VARCHAR(50)) AS maximum
FROM sys.configurations
WHERE name IN (
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max server memory (MB)',
    'min server memory (MB)',
    'optimize for ad hoc workloads',
    'max worker threads'
)
ORDER BY name;
