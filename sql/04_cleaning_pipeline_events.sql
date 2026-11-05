/* =====================================================================
   04_cleaning_pipeline_events.sql
   Cleans stg_pipeline_events. Run after 03_cleaning_devices.sql
   (it joins to the cleaned stg_devices for intake dates).

   Steps
   1. Replace employee names with employee ids (employees dimension)
   2. Find and repair duplicate events (one real event = device_id + stage)
   3. Set event_timestamp to NULL where it is earlier than the device's
      intake date and cannot be recovered. The event row is kept (the
      device did pass through that stage); only the unknown time is
      NULL. A made-up timestamp would corrupt stage durations.

   event_id is text in staging: casts are used wherever ids are compared.
   ===================================================================== */

USE device_pipeline;

-- Index for the self-joins below
CREATE INDEX i_deviceid_stage ON stg_pipeline_events(device_id, stage);

-- ---------------------------------------------------------------------
-- 1. Employees: names -> ids
-- ---------------------------------------------------------------------
-- Run once only: re-running adds the names again.
INSERT INTO employees (emp_name)
SELECT DISTINCT handled_by FROM stg_pipeline_events;

ALTER TABLE stg_pipeline_events ADD COLUMN new_handled_by INTEGER AFTER handled_by;

UPDATE stg_pipeline_events p
JOIN employees e ON p.handled_by = e.emp_name
SET p.new_handled_by = e.emp_id;

-- Expected: 0 (every event matched an employee)
SELECT COUNT(*) AS unmatched_employee_rows
FROM stg_pipeline_events
WHERE new_handled_by IS NULL;

ALTER TABLE stg_pipeline_events DROP COLUMN handled_by;
ALTER TABLE stg_pipeline_events RENAME COLUMN new_handled_by TO handled_by;

-- ---------------------------------------------------------------------
-- 2. Duplicate events
-- ---------------------------------------------------------------------
-- Duplicate pairs (952 expected)
SELECT COUNT(*) AS duplicate_pairs
FROM (SELECT 1 FROM stg_pipeline_events
      GROUP BY device_id, stage HAVING COUNT(*) > 1) x;

-- Pairs whose two copies differ (12 expected, all in event_timestamp)
SELECT a.device_id, a.stage,
       a.event_id AS event_id_1, b.event_id AS event_id_2,
       a.event_timestamp AS ts_1, b.event_timestamp AS ts_2,
       d.intake_date
FROM stg_pipeline_events a
JOIN stg_pipeline_events b
  ON a.device_id = b.device_id AND a.stage = b.stage
 AND CAST(a.event_id AS UNSIGNED) < CAST(b.event_id AS UNSIGNED)
JOIN stg_devices d ON b.device_id = d.device_id
WHERE a.event_timestamp <> b.event_timestamp
   OR a.handled_by <> b.handled_by;

-- Repair: where one copy is earlier than intake, take the other copy's value
UPDATE stg_pipeline_events a
JOIN stg_pipeline_events b
  ON a.device_id = b.device_id AND a.stage = b.stage
 AND CAST(a.event_id AS UNSIGNED) < CAST(b.event_id AS UNSIGNED)
JOIN stg_devices d ON b.device_id = d.device_id
SET a.event_timestamp = CASE WHEN a.event_timestamp < d.intake_date
                             THEN b.event_timestamp ELSE a.event_timestamp END,
    b.event_timestamp = CASE WHEN b.event_timestamp < d.intake_date
                             THEN a.event_timestamp ELSE b.event_timestamp END
WHERE a.event_timestamp <> b.event_timestamp
   OR a.handled_by <> b.handled_by;

-- Checks (both expected 0): no pair still disagrees, none still before intake
SELECT COUNT(*) AS pairs_still_different
FROM stg_pipeline_events a
JOIN stg_pipeline_events b
  ON a.device_id = b.device_id AND a.stage = b.stage
 AND CAST(a.event_id AS UNSIGNED) < CAST(b.event_id AS UNSIGNED)
WHERE a.event_timestamp <> b.event_timestamp
   OR a.handled_by <> b.handled_by;

SELECT COUNT(*) AS pairs_still_before_intake
FROM stg_pipeline_events a
JOIN stg_pipeline_events b
  ON a.device_id = b.device_id AND a.stage = b.stage
 AND CAST(a.event_id AS UNSIGNED) < CAST(b.event_id AS UNSIGNED)
JOIN stg_devices d ON b.device_id = d.device_id
WHERE a.event_timestamp < d.intake_date
   OR b.event_timestamp < d.intake_date;

-- Remove one copy of each pair (the higher event_id).
-- CAST matters: event_id is text, and MAX() on text would pick '406'
-- over '32034'. This was the cause of an earlier defect.
DELETE FROM stg_pipeline_events
WHERE CAST(event_id AS UNSIGNED) IN (
    SELECT dup_row_to_delete
    FROM (SELECT MAX(CAST(event_id AS UNSIGNED)) AS dup_row_to_delete
          FROM stg_pipeline_events
          GROUP BY device_id, stage
          HAVING COUNT(*) > 1) AS a);

-- Expected: 0 duplicate groups and 31,732 rows
SELECT COUNT(*) AS duplicate_groups_left
FROM (SELECT 1 FROM stg_pipeline_events
      GROUP BY device_id, stage HAVING COUNT(*) > 1) x;

SELECT COUNT(*) AS events_after_cleaning FROM stg_pipeline_events;

-- ---------------------------------------------------------------------
-- 3. Events earlier than intake date that could not be recovered -> NULL
-- ---------------------------------------------------------------------
UPDATE stg_pipeline_events p
JOIN stg_devices d ON p.device_id = d.device_id
SET p.event_timestamp = NULL
WHERE p.event_timestamp < d.intake_date;

SELECT COUNT(*) AS events_with_unknown_time
FROM stg_pipeline_events
WHERE event_timestamp IS NULL;

COMMIT;
