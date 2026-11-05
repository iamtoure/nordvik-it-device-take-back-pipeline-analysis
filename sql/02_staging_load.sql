/* =====================================================================
   02_staging_load.sql
   
   Staging layer: loosely typed tables that accept 100% of the raw rows.
   Run after 01_schema_ddl.sql.

   Why staging exists: loading the messy CSVs straight into the typed,
   constrained tables rejected rows silently (devices 5,883 of 6,180;
   pipeline_events 0 of 32,684; outcomes 4,060 of 6,000). Staging tables
   are all text, with no keys, so nothing is rejected. All cleaning
   happens afterwards in SQL, where it can be inspected and counted.

   Load step (done outside SQL, with the import wizard):
     the messy CSVs go into stg_devices, stg_pipeline_events and
     stg_outcomes. Expected row counts: 6,180 / 32,684 / 6,000.
     The dimension tables (device_categories, warehouses, customers,
     employees source) are loaded straight into the production tables.
   ===================================================================== */

USE device_pipeline;

CREATE TABLE IF NOT EXISTS stg_devices (
    device_id     VARCHAR(10),
    customer_id   VARCHAR(10),
    intake_date   VARCHAR(30),
    category_id   VARCHAR(10),
    warehouse_id  VARCHAR(10),
    brand         VARCHAR(50),
    model         VARCHAR(50),
    serial_number VARCHAR(30),
    notes         VARCHAR(150)
);

CREATE TABLE IF NOT EXISTS stg_pipeline_events (
    event_id        VARCHAR(10),
    device_id       VARCHAR(10),
    stage           VARCHAR(50),
    event_timestamp VARCHAR(50),
    handled_by      VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS stg_outcomes (
    device_id        VARCHAR(10),
    final_status     VARCHAR(30),
    listed_price     VARCHAR(50),
    sale_price       VARCHAR(50),
    sale_date        VARCHAR(50),
    shipping_carrier VARCHAR(30)
);

-- Row-count check after the CSV import
SELECT 'stg_devices' AS tbl, COUNT(*) AS row_count FROM stg_devices
UNION ALL
SELECT 'stg_pipeline_events', COUNT(*) FROM stg_pipeline_events
UNION ALL
SELECT 'stg_outcomes', COUNT(*) FROM stg_outcomes;
