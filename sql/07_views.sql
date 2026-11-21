/* =====================================================================
   07_views.sql
   Goal 1 - Standing operational views
   Question answered: what is the current state of devices in the
   pipeline right now?

   Run after 06_load_production.sql. Creates three views that the later
   analysis and the stored procedures build on:
     1.1 v_device_current_stage  furthest pipeline stage of each device
     1.2 v_stage_durations       days spent between consecutive stages
     1.3 v_device_overview       one row per device, with descriptive
                                 attributes and its current stage

   Pipeline order (used by every view below):
     received -> data_wipe_security_check -> graded -> refurbished
     -> listed -> sold
   Stages are ordered by their position in the process, never by
   event_id or timestamp alone. Event ids do not follow process order,
   and ordering by them produced negative durations and wrong current
   stages.
   ===================================================================== */

USE device_pipeline;

-- ---------------------------------------------------------------------
-- 1.1 v_device_current_stage
--     One row per device: the furthest stage it has reached.
--
--     Events are ranked per device by process position (highest first),
--     with the latest timestamp as tie-breaker, and rank 1 is kept.
--     Undated events (NULL timestamp) still count as having happened;
--     only the time is unknown. MySQL sorts NULLs lowest, so in the
--     tie-breaker a dated event wins over an undated one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_device_current_stage AS
SELECT
    a.event_id,
    a.device_id,
    a.stage,
    a.event_timestamp
FROM (
    SELECT
        event_id,
        device_id,
        stage,
        event_timestamp,
        ROW_NUMBER() OVER w AS stage_rank
    FROM
        pipeline_events
    WINDOW w AS (PARTITION BY device_id ORDER BY
        CASE stage
            WHEN 'received'                 THEN 1
            WHEN 'data_wipe_security_check' THEN 2
            WHEN 'graded'                   THEN 3
            WHEN 'refurbished'              THEN 4
            WHEN 'listed'                   THEN 5
            WHEN 'sold'                     THEN 6
        END DESC, event_timestamp DESC)
) a
WHERE a.stage_rank = 1;

-- ---------------------------------------------------------------------
-- 1.2 v_stage_durations
--     Days from the previous stage to this stage, per event.
--     duration_days is the time spent getting INTO this stage.
--
--     Notes for readers of the output
--     - The first stage (received) has no previous stage, so its
--       duration is NULL.
--     - Whole days only: TIMESTAMPDIFF(DAY, ...) drops the remainder.
--     - If an event or its predecessor has no timestamp, the duration
--       is NULL. These rows drop out of averages automatically.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stage_durations AS
SELECT
    event_id,
    device_id,
    stage,
    event_timestamp,
    TIMESTAMPDIFF(DAY, LAG(event_timestamp) OVER w, event_timestamp) AS duration_days
FROM pipeline_events
WINDOW w AS (PARTITION BY device_id ORDER BY CASE stage
    WHEN 'received'                 THEN 1
    WHEN 'data_wipe_security_check' THEN 2
    WHEN 'graded'                   THEN 3
    WHEN 'refurbished'              THEN 4
    WHEN 'listed'                   THEN 5
    WHEN 'sold'                     THEN 6
END ASC);

-- ---------------------------------------------------------------------
-- 1.3 v_device_overview
--     One row per device: what it is, who it came from, where it is
--     held, its current stage (from 1.1), its final status and its
--     inferred resolved date.
--
--     Joins
--     - Inner joins for the device's category, customer, warehouse and
--       current stage. No device can drop out: the 'Unknown' warehouse
--       and category rows added in 03_cleaning_devices.sql stand in for
--       values that could not be recovered, and the foreign keys
--       guarantee the customer exists.
--     - Left joins for the outcome and for the graded and listed events,
--       so a device without one of them keeps its row with NULLs. Each
--       event join is limited to one stage in its ON clause, so it
--       matches at most one event, and the view keeps exactly one row
--       per device (6,000). A single join on both stages would give
--       listed devices two rows.
--
--     resolved_date: the business rules for when a device left the
--     pipeline, defined here once and used by unresolved_devices and by
--     the Power BI report:
--       sold               -> sale date
--       unsold_written_off -> listed date + 60 days (write-off rule)
--       recycled/disposed  -> graded date
--     Each status has its own branch and there is no ELSE, so an
--     unexpected status gets NULL instead of a wrong date.
--     NULL also means the resolving event has no timestamp.
--
--     Blank brands (about 234) are left as they are for Power Query.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_device_overview AS
SELECT
    d.device_id,
    dc.category_name,
    d.brand,
    d.model,
    d.serial_number,
    c.customer_name,
    c.segment,
	w.city   AS warehouse,
    d.intake_date,
    vd.stage AS current_stage,
    CASE o.final_status
                WHEN 'sold'					THEN o.sale_date
                WHEN 'recycled'	 			THEN p.event_timestamp
                WHEN 'disposed'	 			THEN p.event_timestamp
                WHEN 'unsold_written_off'	THEN DATE_ADD(pe.event_timestamp, INTERVAL 60 DAY)
	END AS resolved_date,
    o.final_status
FROM devices d
    JOIN device_categories dc    	ON d.category_id  = dc.category_id
    JOIN customers c             	ON d.customer_id  = c.customer_id
    JOIN warehouses w            	ON d.warehouse_id = w.warehouse_id
    JOIN v_device_current_stage vd 	ON d.device_id  = vd.device_id
	LEFT JOIN outcomes o 			ON d.device_id = o.device_id
    LEFT JOIN pipeline_events p		ON d.device_id = p.device_id AND p.stage = 'graded'
    LEFT JOIN pipeline_events pe	ON d.device_id = pe.device_id AND pe.stage = 'listed';

-- ---------------------------------------------------------------------
-- Quick checks
-- ---------------------------------------------------------------------
-- Expected: one row per device (6,000)
SELECT COUNT(*) AS devices_in_overview FROM v_device_overview;

-- Expected: same number of rows as pipeline_events (31,732)
SELECT COUNT(*) AS rows_in_durations FROM v_stage_durations;
