/* =====================================================================
   08_analysis_goal2.sql
   Goal 2 - Bottleneck and exception detection
   Question answered: which warehouses, categories or segments
   underperform relative to their own baseline?

   Run after 07_views.sql. Every query reads the views, so it needs no
   other setup.

   Method used throughout
   - Baseline = the network-wide average duration of a stage.
   - A group (warehouse, category or segment) is flagged when its
     average for that stage is more than 30% above the baseline
     (pct_gap > 30).
   - The 30% threshold is a starting assumption, not a statistical
     result. Every normal group in this data sits well inside it and the
     real problems sit well outside it. In a real organisation it would
     be agreed with operations and revised against live data.
   - Rows with an 'Unknown' warehouse or category are excluded from
     comparisons, because they cannot be located.
   - The window averages repeat on every row of a group, so GROUP BY
     collapses them to one row per group.
   - NULLIF(..., 0) protects every division from division by zero.
   - Durations are whole days (see v_stage_durations), and events with an
     unknown timestamp have no duration, so they drop out of the averages.
   ===================================================================== */

USE device_pipeline;

-- =====================================================================
-- 2.1 Warehouse comparison, per stage
--     Which warehouse runs slower than the cross-warehouse average at
--     each specific stage?
--     Result: one row. Oslo at 'graded' is about 60% above baseline.
-- =====================================================================
SELECT
    a.warehouse,
    a.stage,
    ROUND(a.avg_duration_per_stage, 2),
    ROUND(a.avg_duration_per_warehouse_per_stage, 2),
    ROUND(100 * ((a.avg_duration_per_warehouse_per_stage - a.avg_duration_per_stage) / NULLIF(a.avg_duration_per_stage, 0)), 2) AS pct_gap
FROM (
    SELECT
        s.device_id,
        d.warehouse,
        s.stage,
        s.duration_days,
        AVG(s.duration_days) OVER (PARTITION BY s.stage) AS avg_duration_per_stage,
		AVG(s.duration_days) OVER (PARTITION BY d.warehouse, s.stage) AS avg_duration_per_warehouse_per_stage
    FROM
        v_stage_durations s
            JOIN
        v_device_overview d ON s.device_id = d.device_id
    ) a
WHERE a.warehouse <> 'Unknown'
GROUP BY a.warehouse, a.stage
HAVING pct_gap > 30;

-- =====================================================================
-- 2.2 Category comparison, per stage
--     Which device category runs slower than the average at each
--     specific stage?
--     Baseline: the average of the stage across all categories.
--     Result: one row. Phone at 'data_wipe_security_check' is about 84%
--     above baseline.
-- =====================================================================
SELECT
    a.category_name,
    a.stage,
    ROUND(a.avg_duration_per_stage, 2),
    ROUND(a.avg_duration_per_category_per_stage, 2),
    ROUND(100 * ((a.avg_duration_per_category_per_stage - a.avg_duration_per_stage) / NULLIF(a.avg_duration_per_stage, 0)), 2) AS pct_gap
FROM (
    SELECT
        s.device_id,
        d.category_name,
        s.stage,
        s.duration_days,
        AVG(s.duration_days) OVER (PARTITION BY s.stage) AS avg_duration_per_stage,
        AVG(s.duration_days) OVER (PARTITION BY d.category_name, s.stage) AS avg_duration_per_category_per_stage
    FROM
        v_stage_durations s
            JOIN
        v_device_overview d ON s.device_id = d.device_id) a
WHERE a.category_name <> 'Unknown'
GROUP BY a.category_name, a.stage
HAVING pct_gap > 30;

-- =====================================================================
-- 2.3 Customer segment comparison
--     Does LCP vs. SMB show a different processing pattern anywhere in
--     the pipeline?
--     No threshold is applied: every segment/stage pair is listed so the
--     gaps can be read directly.
--     Result: no significant segment effect.
-- =====================================================================
SELECT
    a.segment,
    a.stage,
    ROUND(a.avg_duration_per_stage, 2),
    ROUND(a.avg_duration_per_segment_per_stage, 2),
    ROUND(100 * ((a.avg_duration_per_segment_per_stage - a.avg_duration_per_stage) / NULLIF(a.avg_duration_per_stage,0)), 2) AS pct_gap
FROM (
    SELECT
        s.device_id,
        d.segment,
        s.stage,
        s.duration_days,
        AVG(s.duration_days) OVER (PARTITION BY s.stage) AS avg_duration_per_stage,
        AVG(s.duration_days) OVER (PARTITION BY d.segment, s.stage) AS avg_duration_per_segment_per_stage
    FROM
        v_stage_durations s
            JOIN
        v_device_overview d ON s.device_id = d.device_id
    ) a
GROUP BY a.segment, a.stage;

-- =====================================================================
-- 2.4 Individual device exception flagging
--     Which specific devices are outliers relative to their own peer
--     group (same category + same stage)?
--
--     distance_from_avg is a z-score: how many standard deviations a
--     device's duration is above its peer-group average. Flag: above 3.
--     STDDEV is the population standard deviation.
--
--     Reading the result
--     - The peer group decides what this method can see. Slowness that
--       cuts across groups (such as one warehouse) shows up as
--       individual outliers. Slowness that lines up with the peer group
--       (all Phones at one stage) is absorbed into the group's own
--       baseline. 2.1/2.2 and 2.4 are complementary.
--     - In a very small group a z-score cannot reach 3, so groups with
--       ten events or fewer cannot flag anything.
--     - Devices with an 'Unknown' category are excluded.
--     - A blank brand in the output is a known data gap (Power Query).
-- =====================================================================
SELECT
    b.device_id,
    b.category_name,
    b.brand,
    b.model,
    b.serial_number,
    b.stage,
    b.duration_days,
	ROUND(b.avg_duration_per_category_per_stage, 2),
    ROUND(b.std_duration, 2),
    b.warehouse,
    ROUND(b.distance_from_avg, 2)
FROM
    (SELECT
        a.device_id,
        a.category_name,
        a.brand,
        a.model,
        a.serial_number,
        a.stage,
        a.duration_days,
        a.warehouse,
        a.avg_duration_per_category_per_stage,
        a.std_duration,
        a.duration_days - avg_duration_per_category_per_stage/NULLIF(a.std_duration, 0) AS distance_from_avg
    FROM
        (SELECT
            s.device_id,
            d.category_name,
            d.brand,
            d.model,
            d.serial_number,
            s.stage,
            s.duration_days,
            d.warehouse,
			AVG(s.duration_days) OVER (PARTITION BY d.category_name, s.stage) AS avg_duration_per_category_per_stage,
            STDDEV(s.duration_days) OVER (PARTITION BY d.category_name, s.stage) AS std_duration
        FROM
            v_stage_durations s
                JOIN
            v_device_overview d ON s.device_id = d.device_id) a
    WHERE a.category_name <> 'Unknown') b
WHERE b.distance_from_avg > 3;

-- =====================================================================
-- 2.5 Dead-stock / non-resale rate
--     What fraction of intake never becomes resalable, and does that
--     rate vary by category or warehouse?
--
--     Two kinds of loss are measured:
--     - Failed devices: final_status 'disposed' or 'recycled'
--       (never resalable). Rate = failed / all devices in the group.
--     - Written-off devices: final_status 'unsold_written_off'
--       (listed but never sold). Rate = written off / listed, where
--       listed = sold + written off.
--     Each group's rate is compared with the network-wide rate
--     (pct_gap, same 30% line). The comparison is a percentage of a
--     rate, so a large gap on a small rate can be only a few devices.
--     'Unknown' groups are excluded.
--     Result: no group reaches the 30% line. Loss is network-wide, not
--     concentrated in one category or site. The largest gap is Tablet
--     write-offs at about +22% (roughly 12 devices more than expected).
-- =====================================================================

-- 2.5.1 Failed rate by category
SELECT
    f.category_name,
    f.total_devices,
    f.failed_devices,
    ROUND(f.failed_rate,2) AS failed_rate,
    ROUND(f.overall_rate,2) AS overall_rate,
    ROUND(100 * ((f.failed_rate - f.overall_rate)/NULLIF(f.overall_rate, 0)), 2) AS pct_gap
FROM (
    SELECT
        g.category_name,
        g.total_devices,
        g.failed_devices,
        g.failed_rate,
        100 * g.failed/g.grand_count AS overall_rate
    FROM (SELECT
            o.category_name,
            COUNT(*) AS total_devices,
            a.failed_devices,
            100 * a.failed_devices / COUNT(*) AS failed_rate,
            a.grand_count,
            SUM(a.failed_devices) OVER() AS failed
        FROM
            v_device_overview o
                JOIN
            (SELECT
                vd.category_name,
                SUM(COUNT(*)) OVER () AS grand_count,
                COUNT(CASE WHEN o.final_status IN
                    ('disposed', 'recycled') THEN 1
                    ELSE NULL
                    END) AS failed_devices
            FROM
                outcomes o
                    JOIN
                v_device_overview vd ON o.device_id = vd.device_id
            WHERE
                vd.category_name <> 'Unknown'
            GROUP BY vd.category_name) a ON o.category_name = a.category_name
        GROUP BY o.category_name) g) f
ORDER BY f.category_name;

-- 2.5.2 Failed rate by warehouse
SELECT
    f.warehouse,
    f.total_devices,
    f.failed_devices,
    ROUND(f.failed_rate,2) AS failed_rate,
    ROUND(f.overall_rate,2) AS overall_rate,
    ROUND(100 * ((f.failed_rate - f.overall_rate)/NULLIF(f.overall_rate, 0)), 2) AS pct_gap
FROM (
    SELECT
        g.warehouse,
        g.total_devices,
        g.failed_devices,
        g.failed_rate,
        100 * g.failed/g.grand_count AS overall_rate
    FROM (SELECT
            vo.warehouse,
            COUNT(*) AS total_devices,
            a.failed_devices,
            100 * a.failed_devices / COUNT(*) AS failed_rate,
            a.grand_count,
            SUM(a.failed_devices) OVER() AS failed
        FROM
            v_device_overview vo
                JOIN
            (SELECT
                vd.warehouse,
                COUNT(CASE WHEN o.final_status IN
                        ('disposed', 'recycled') THEN 1
                    ELSE NULL
                    END) AS failed_devices,
                SUM(COUNT(*)) OVER () AS grand_count
            FROM
                outcomes o
                    JOIN
                v_device_overview vd ON o.device_id = vd.device_id
            WHERE
                vd.warehouse <> 'Unknown'
            GROUP BY vd.warehouse) a ON vo.warehouse = a.warehouse
        GROUP BY vo.warehouse) g) f
ORDER BY f.warehouse;

-- 2.5.3 Written-off rate by category
SELECT
    c.category_name,
    c.listed_devices,
    c.written_off_devices,
    ROUND(c.written_off_rate,2) AS written_off_rate,
    ROUND(c.overall_rate,2) AS overall_rate,
    ROUND(100 * ((c.written_off_rate - c.overall_rate)/NULLIF(c.overall_rate, 0)), 2) AS pct_gap
FROM (
    SELECT
        b.category_name,
        b.listed_devices,
        b.written_off_devices,
        100 * b.written_off_devices/b.listed_devices AS written_off_rate,
        100 * b.off_written/b.listed AS overall_rate
    FROM
        (SELECT
            a.category_name,
            a.written_off_devices,
            a.listed_devices,
            SUM(a.listed_devices) OVER() AS listed,
            SUM(a.written_off_devices) OVER() AS off_written
        FROM
            (SELECT
                vd.category_name,
                COUNT(CASE WHEN o.final_status IN
                    ('unsold_written_off', 'sold') THEN 1
                    ELSE NULL
                    END) AS listed_devices,
                COUNT(CASE WHEN o.final_status IN
                    ('unsold_written_off') THEN 1
                    ELSE NULL
                    END) AS written_off_devices
            FROM
                outcomes o
                    JOIN
                v_device_overview vd ON o.device_id = vd.device_id
            WHERE
                vd.category_name <> 'Unknown'
            GROUP BY vd.category_name) a
        ) b) c
ORDER BY c.category_name;

-- 2.5.4 Written-off rate by warehouse
SELECT
    c.warehouse,
    c.listed_devices,
    c.written_off_devices,
    ROUND(c.written_off_rate,2) AS written_off_rate,
    ROUND(c.overall_rate,2) AS overall_rate,
    ROUND(100 * ((c.written_off_rate - c.overall_rate)/NULLIF(c.overall_rate, 0)), 2) AS pct_gap
FROM (
    SELECT
        b.warehouse,
        b.listed_devices,
        b.written_off_devices,
        100 * b.written_off_devices/b.listed_devices AS written_off_rate,
        100 * b.off_written/b.listed AS overall_rate
    FROM
        (SELECT
            a.warehouse,
            a.written_off_devices,
            a.listed_devices,
            SUM(a.listed_devices) OVER() AS listed,
            SUM(a.written_off_devices) OVER() AS off_written
        FROM
            (SELECT
                vd.warehouse,
                COUNT(CASE WHEN o.final_status IN
                        ('unsold_written_off', 'sold') THEN 1
                    ELSE NULL
                    END) AS listed_devices,
                COUNT(CASE WHEN o.final_status IN
                    ('unsold_written_off') THEN 1
                    ELSE NULL
                    END) AS written_off_devices
            FROM
                outcomes o
                    JOIN
                v_device_overview vd ON o.device_id = vd.device_id
            WHERE
                vd.warehouse <> 'Unknown'
            GROUP BY vd.warehouse) a
        ) b) c
ORDER BY c.warehouse;
