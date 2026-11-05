/* =====================================================================
   06_load_production.sql
   Moves the cleaned staging data into the production tables.
   Run last, after 03, 04 and 05. Order matters: devices first, then
   pipeline_events and outcomes, which reference devices.

   Type conversions
   - ids and counts: text -> unsigned integer
   - category_id: the generator wrote some ids as '4.0', so it goes
     through DECIMAL first
   - blank text in the price, date and carrier columns -> NULL
   Run SHOW WARNINGS after each load. Any warning means a value was
   altered or truncated.
   ===================================================================== */

USE device_pipeline;

INSERT INTO devices
    (device_id, customer_id, intake_date, category_id, warehouse_id,
     brand, model, serial_number, notes)
SELECT
    CAST(device_id AS UNSIGNED),
    CAST(customer_id AS UNSIGNED),
    CAST(intake_date AS DATE),
    CAST(CAST(category_id AS DECIMAL(10,2)) AS UNSIGNED),
    CAST(warehouse_id AS UNSIGNED),
    brand, model, serial_number, notes
FROM stg_devices;
SHOW WARNINGS;

INSERT INTO pipeline_events
    (event_id, device_id, stage, event_timestamp, handled_by)
SELECT
    CAST(event_id AS UNSIGNED),
    CAST(device_id AS UNSIGNED),
    stage,
    CAST(event_timestamp AS DATETIME),
    handled_by
FROM stg_pipeline_events;
SHOW WARNINGS;

INSERT INTO outcomes
    (device_id, final_status, listed_price, sale_price, sale_date, shipping_carrier)
SELECT
    CAST(device_id AS UNSIGNED),
    final_status,
    CAST(NULLIF(listed_price, '') AS DECIMAL(10,2)),
    CAST(NULLIF(sale_price, '')   AS DECIMAL(10,2)),
    CAST(NULLIF(sale_date, '')    AS DATETIME),
    NULLIF(shipping_carrier, '')
FROM stg_outcomes;
SHOW WARNINGS;

COMMIT;

-- Tie-out: production should match the cleaned staging tables
-- Expected: devices 6,000 | pipeline_events 31,732 | outcomes 6,000
SELECT 'devices' AS tbl,
       (SELECT COUNT(*) FROM stg_devices) AS staging_rows,
       (SELECT COUNT(*) FROM devices)     AS production_rows
UNION ALL
SELECT 'pipeline_events',
       (SELECT COUNT(*) FROM stg_pipeline_events),
       (SELECT COUNT(*) FROM pipeline_events)
UNION ALL
SELECT 'outcomes',
       (SELECT COUNT(*) FROM stg_outcomes),
       (SELECT COUNT(*) FROM outcomes);
