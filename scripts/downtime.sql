WITH settings AS (
    SELECT
        interval '1 second' AS expected_writer_interval,
        interval '500 milliseconds' AS jitter_budget
),
ordered AS (
    SELECT
        id,
        created_at,
        source_node,
        LAG(created_at) OVER (ORDER BY created_at, id) AS previous_created_at,
        LAG(source_node) OVER (ORDER BY created_at, id) AS previous_source_node
    FROM timestamp_log
    -- Only use rows written by the continuous writer so check inserts do not skew gap calculations.
    WHERE source_node IN ('postgres-master', 'postgres-slave')
),
gaps AS (
    SELECT
        previous_created_at,
        created_at,
        previous_source_node,
        source_node,
        created_at - previous_created_at AS gap
    FROM ordered
    WHERE previous_created_at IS NOT NULL
)
SELECT
    previous_created_at,
    created_at,
    previous_source_node,
    source_node,
    gap,
    ROUND(EXTRACT(EPOCH FROM gap)::numeric, 3) AS gap_seconds,
    ROUND(
        GREATEST(
            EXTRACT(EPOCH FROM gap - settings.expected_writer_interval),
            0
        )::numeric,
        3
    ) AS seconds_above_expected_interval,
    gap > settings.expected_writer_interval + settings.jitter_budget AS likely_failover_gap
FROM gaps
CROSS JOIN settings
ORDER BY gap DESC
LIMIT 10;
