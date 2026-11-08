/* =====================================================================
   09_exception_snapshot.sql
   Goal 3 - Stored procedure 1: exception_snapshot

   Turns the individual-device outlier query from Objective 2.4 into a
   reusable report: pick a date range and a baseline mode, and get the
   flagged devices for that range.

   Run after 07_views.sql (it reads v_stage_durations and
   v_device_overview).
   Companion procedure: 10_p_unresolved_devices.sql

   USAGE
     CALL exception_snapshot('2025-01-01', '2025-04-30', 1);  -- baseline from first activity
     CALL exception_snapshot('2025-03-31', '2025-04-30', 0);  -- baseline from the window only
   ===================================================================== */

USE device_pipeline;

DROP PROCEDURE IF EXISTS exception_snapshot;

DELIMITER $$

CREATE PROCEDURE exception_snapshot(
    IN p_start_date DATE,
    IN p_end_date   DATE,
    IN p_full_mode  TINYINT   -- 1 = baseline from first activity, 0 = window only
)
BEGIN
    /*
    =====================================================================
    PROCEDURE: exception_snapshot
    PURPOSE:   Returns the individual-device outliers from Objective 2.4
               (z-score above 3 within the same category and stage) for a
               chosen date range, with the most extreme first.

    PARAMETERS
      p_start_date  start of the output window.
      p_end_date    end of the output window. The whole end date is
                    included.
      p_full_mode   1 or 0. Any other value is rejected.

    BASELINE MODES (what the average and spread are calculated from)
      1  from the first activity in the data up to the end date
      0  from the start date to the end date only
    The output is always limited to events inside the requested window,
    in both modes. The mode changes only the group the device is
    compared with. The spread is the population standard deviation
    (divides by n), the same as in 2.4.

    ERRORS (the procedure stops with a message)
      - any parameter is NULL
      - p_start_date is later than p_end_date
      - p_start_date is earlier than the first activity in the data, or
        later than the last activity
      - p_end_date is outside the same range
      - p_full_mode is not 0 or 1
      - there are no dated events at all

    OUTPUT COLUMNS
      The device and its flagged event, plus the group average and
      spread, distance_from_avg (the z-score), baseline_start,
      as_of_date, baseline_mode and baseline_count (events behind the
      comparison group).

    NOTES FOR READERS
      - A category and stage group with 10 or fewer events cannot flag
        anything, because a z-score cannot reach 3 in a group that
        small. An empty result for a short window can mean "too few
        events" as well as "nothing unusual".
      - Devices still unsold at the end date have not used up their 60
        days, so sold-stage results at an early snapshot are
        provisional.
      - Devices with an 'Unknown' category are excluded.
    =====================================================================
    */

    -- Boundaries of the data, used to validate the dates
    DECLARE absolute_min DATETIME;
    DECLARE absolute_max DATETIME;

    -- Window used to calculate the baseline
    DECLARE calc_start DATETIME;
    DECLARE calc_end   DATETIME;

    -- Window used to limit the output
    DECLARE output_start DATETIME;
    DECLARE output_end   DATETIME;

    -- 1. Store the date boundaries
    SELECT MIN(event_timestamp), MAX(event_timestamp)
    INTO absolute_min, absolute_max
    FROM v_stage_durations;

    -- 2. Validation: no dated events at all
    IF absolute_min IS NULL OR absolute_max IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: No valid event records found in the source table.';
    END IF;

    -- 3. Validation: NULL date arguments
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: start_date and end_date parameters cannot be NULL/empty.';
    END IF;

    -- 4. Validation: start date after end date
    IF p_start_date > p_end_date THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: start_date cannot be later than end_date.';
    END IF;

    -- 5. Validation: start date inside the data
    IF p_start_date < CAST(absolute_min AS DATE) OR p_start_date > CAST(absolute_max AS DATE) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: Invalid start_date. It falls outside available event records.';
    ELSE
        SET output_start = CAST(p_start_date AS DATETIME);
    END IF;

    -- 6. Validation: end date inside the data
    IF p_end_date < CAST(absolute_min AS DATE) OR p_end_date > CAST(absolute_max AS DATE) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: Invalid end_date. It falls outside available event records.';
    ELSE
        -- Midnight of the following day, so the whole end date is
        -- included and fractional seconds cannot slip past it
        SET output_end = DATE_ADD(CAST(p_end_date AS DATETIME), INTERVAL 1 DAY);
    END IF;

    -- 7. Baseline mode: choose where the baseline starts
    IF p_full_mode = 1 THEN
        -- Baseline from the first activity in the data
        SELECT MIN(event_timestamp) INTO calc_start FROM v_stage_durations;
    ELSEIF p_full_mode = 0 THEN
        -- Baseline from the requested window only
        SET calc_start = output_start;
    ELSE
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Validation Error: 1 for a baseline from the first activity, 0 for the requested window only';
    END IF;

    -- The baseline always stops at the end of the requested window
    SET calc_end = output_end;

    -- 8. Query: compute z-scores on the baseline, flag above 3, then
    --    show only the flagged events that fall in the output window
    WITH flagged_devices AS (
        SELECT
            b.event_id,
            b.device_id,
            b.category_name,
            b.brand,
            b.model,
            b.serial_number,
            b.stage,
            b.event_timestamp,
            b.duration_days,
			b.avg_duration_per_category_per_stage,
            b.std_duration,
            b.warehouse,
            ROUND(b.distance_from_avg),
            b.baseline_count
        FROM
            (SELECT
                a.event_id,
                a.device_id,
                a.category_name,
                a.brand,
                a.model,
                a.serial_number,
                a.stage,
                a.event_timestamp,
                a.duration_days,
                a.warehouse,
                a.avg_duration_per_category_per_stage,
                a.std_duration,
                -- Zero-division protection if the spread is 0
                (a.duration_days - avg_duration_per_category_per_stage)/NULLIF(a.std_duration, 0) AS distance_from_avg,
                a.baseline_count
            FROM
                (SELECT
                    s.event_id,
                    s.device_id,
                    d.category_name,
                    d.brand,
                    d.model,
                    d.serial_number,
                    s.stage,
                    s.event_timestamp,
                    s.duration_days,
                    d.warehouse,
                    AVG(s.duration_days) OVER (PARTITION BY d.category_name, s.stage) AS avg_duration_per_category_per_stage,
                    ROUND(STDDEV(s.duration_days) OVER (PARTITION BY d.category_name, s.stage), 2) AS std_duration,
                    COUNT(s.duration_days) OVER (PARTITION BY d.category_name, s.stage) AS baseline_count
                FROM
                    v_stage_durations s
                        JOIN
                    v_device_overview d ON s.device_id = d.device_id
                -- Baseline window: decides which events feed the average
                WHERE s.event_timestamp >= calc_start
                  AND s.event_timestamp < calc_end
                ) a
            WHERE a.category_name <> 'Unknown') b
        WHERE b.distance_from_avg > 3)
    SELECT
        fd.device_id,
        fd.category_name,
        fd.brand,
        fd.model,
        fd.serial_number,
        fd.warehouse,
        fd.stage,
        fd.event_timestamp,
        fd.duration_days,
        ROUND(fd.avg_duration_per_category_per_stage, 2),
        ROUND(fd.std_duration, 2),
        ROUND(fd.distance_from_avg, 2),
        CAST(calc_start AS DATE) AS baseline_start,
        p_end_date  AS as_of_date,
        p_full_mode AS baseline_mode,
        fd.baseline_count
    FROM
        flagged_devices fd
    -- Output window: limits what is shown without changing the baseline
    WHERE fd.event_timestamp >= output_start
      AND fd.event_timestamp < output_end
    ORDER BY fd.distance_from_avg DESC;
END $$

DELIMITER ;
