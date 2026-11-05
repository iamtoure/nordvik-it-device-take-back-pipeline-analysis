/* =====================================================================
   p_unresolved_devices(p_as_of_date)
   Nordvik IT - device take-back pipeline

   PURPOSE
   Lists every device that had ARRIVED by the as-of date and was NOT YET
   RESOLVED on that date, with the pipeline stage it had reached as of
   that date and how long it had been in the pipeline.

   HOW "RESOLVED" IS DEFINED (inferred - no resolved date is recorded)
     sold               -> outcomes.sale_date
     unsold_written_off -> date of the 'listed' event + 60 days
                           (60 is the write-off rule used in the data
                            generator; kept in the variable v_write_off_days)
     recycled/disposed  -> date of the 'graded' event
   The outcomes table is final results only. It never labels a device
   as "unresolved", so unresolved is derived by comparing these dates
   with the as-of date.

   AS-OF RULE
   The as-of date counts as a whole day: a device resolved at any time
   on that day is treated as resolved, so only devices resolved on the
   following midnight or later are listed.

   STAGE AS OF THE DATE
   The furthest stage with an event dated on or before the as-of date.
   A device that arrived but has no dated event yet shows 'received'.

   KNOWN LIMITATIONS
   1. Devices whose resolving event has no timestamp get a NULL
      resolved_date. They cannot be confirmed as unresolved, but are
      kept in the list so they are not silently dropped.
   2. hidden_stage_flag = 'yes' means the device has an undated event
      at a stage beyond the reported stage, and nothing earlier in its
      journey happened after the as-of date. The true stage may
      therefore be further along than shown. 'no' means the reported
      stage is reliable.

   USAGE   CALL p_unresolved_devices('2025-06-30');
   ===================================================================== */

DROP PROCEDURE IF EXISTS p_unresolved_devices;

DELIMITER $$

CREATE PROCEDURE p_unresolved_devices(
    IN p_as_of_date DATE
)
BEGIN
    DECLARE v_first_event    DATETIME;
    DECLARE v_last_event     DATETIME;
    DECLARE v_as_of_end      DATETIME;      -- midnight AFTER the as-of date
    DECLARE v_write_off_days INT DEFAULT 60;

    -- 1. Validation
    IF p_as_of_date IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: as-of date cannot be NULL.';
    END IF;

    SELECT MIN(event_timestamp), MAX(event_timestamp)
    INTO v_first_event, v_last_event
    FROM pipeline_events
    WHERE event_timestamp IS NOT NULL;

    IF v_first_event IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: no dated pipeline events found.';
    END IF;

    IF p_as_of_date < CAST(v_first_event AS DATE)
       OR p_as_of_date > CAST(v_last_event AS DATE) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: as-of date is outside the available event records.';
    END IF;

    SET v_as_of_end = DATE_ADD(CAST(p_as_of_date AS DATETIME), INTERVAL 1 DAY);

    -- 2. Query
    WITH events AS (
        -- every event, dated or not, with its position in the journey
        SELECT
            device_id,
            stage,
            event_timestamp,
            CASE stage
                WHEN 'received'                 THEN 1
                WHEN 'data_wipe_security_check' THEN 2
                WHEN 'graded'                   THEN 3
                WHEN 'refurbished'              THEN 4
                WHEN 'listed'                   THEN 5
                WHEN 'sold'                     THEN 6
            END AS stage_pos
        FROM pipeline_events
    ),
    resolved AS (
        -- one row per device with its inferred resolved date
        SELECT
            d.device_id,
            d.intake_date,
            o.final_status,
            CASE o.final_status
                WHEN 'sold'               THEN o.sale_date
                WHEN 'unsold_written_off' THEN DATE_ADD(e.event_timestamp, INTERVAL v_write_off_days DAY)
                ELSE e.event_timestamp    -- recycled / disposed: graded date
            END AS resolved_date
        FROM devices d
        JOIN outcomes o ON o.device_id = d.device_id
        LEFT JOIN events e
               ON e.device_id = d.device_id
              AND e.stage = CASE o.final_status
                                WHEN 'unsold_written_off' THEN 'listed'
                                ELSE 'graded'
                            END
        WHERE o.final_status IN ('sold', 'unsold_written_off', 'recycled', 'disposed')
    ),
    furthest AS (
        -- furthest stage with an event dated on or before the as-of date
        SELECT device_id, stage, stage_pos
        FROM (
            SELECT
                device_id, stage, stage_pos,
                ROW_NUMBER() OVER (
                    PARTITION BY device_id
                    ORDER BY stage_pos DESC, event_timestamp DESC
                ) AS rn
            FROM events
            WHERE event_timestamp IS NOT NULL
              AND event_timestamp < v_as_of_end
        ) ranked
        WHERE rn = 1
    )
    SELECT
        r.device_id,
        v.category_name,
        v.brand,
        v.model,
        v.serial_number,
        v.warehouse,
        r.intake_date,
        DATEDIFF(p_as_of_date, r.intake_date)  AS days_in_pipeline,
        COALESCE(f.stage, 'received')          AS stage_as_of_date,
        r.final_status,
        r.resolved_date,                        -- NULL = resolved date unknown
        CASE WHEN EXISTS (
                 SELECT 1
                 FROM events u
                 WHERE u.device_id = r.device_id
                   AND u.event_timestamp IS NULL                  -- undated event
                   AND u.stage_pos > COALESCE(f.stage_pos, 1)     -- beyond reported stage
                   AND NOT EXISTS (                               -- nothing earlier happened later
                         SELECT 1
                         FROM events x
                         WHERE x.device_id = u.device_id
                           AND x.stage_pos < u.stage_pos
                           AND x.event_timestamp >= v_as_of_end)
             ) THEN 'yes' ELSE 'no'
        END AS hidden_stage_flag,
        p_as_of_date AS as_of_date
    FROM resolved r
    JOIN v_device_overview v ON v.device_id = r.device_id
    LEFT JOIN furthest f     ON f.device_id = r.device_id
    WHERE r.intake_date < v_as_of_end                              -- had arrived
      AND (r.resolved_date IS NULL OR r.resolved_date >= v_as_of_end)  -- not yet resolved
    ORDER BY days_in_pipeline DESC;
END $$

DELIMITER ;

/* Checks to run after creating it:
   CALL p_unresolved_devices('2025-06-30');  -- expect 241 rows
       hidden_stage_flag = 'yes' for 9 devices:
       1333, 1936, 2363, 2803, 3299, 4045, 4585, 4626, 2773
       device 5932 must show 'no'
   CALL p_unresolved_devices('2025-11-23');  -- device 1156 should show 'received'
   CALL p_unresolved_devices(NULL);          -- NULL error
   CALL p_unresolved_devices('2030-01-01');  -- out-of-range error
*/
