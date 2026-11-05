/* =====================================================================
   03_cleaning_devices.sql
   Cleans customers.segment and stg_devices. Run after 02_staging_load.sql.

   Because staging columns are text, comparisons and ORDER BY on ids behave
   as text. Cast before comparing numbers.

   Decisions
   - A duplicate device row is repaired from its duplicate partner where
     possible (blank category, warehouse placeholder 99, blank brand).
   - What cannot be recovered gets an honest 'Unknown' dimension row
     (warehouse and category) rather than a guess.
   - Blank brands with no partner stay blank (about 234); they are
     handled later in Power Query.
   ===================================================================== */

USE device_pipeline;

-- ---------------------------------------------------------------------
-- 1. customers.segment: casing and stray whitespace
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_customers AS SELECT * FROM customers;

UPDATE stg_customers SET segment = UPPER(TRIM(segment));

UPDATE customers c
JOIN stg_customers s ON c.customer_id = s.customer_id
SET c.segment = s.segment;

-- ---------------------------------------------------------------------
-- 2. Helper key and index for the self-joins below
--    (without the index the self-joins did full scans and timed out)
-- ---------------------------------------------------------------------
ALTER TABLE stg_devices ADD COLUMN stg_row_id INT AUTO_INCREMENT PRIMARY KEY;
CREATE INDEX i_deviceid ON stg_devices(device_id);

-- ---------------------------------------------------------------------
-- 3. Profiling (what needs cleaning)
-- ---------------------------------------------------------------------
-- Device ids that appear more than once (180 expected)
SELECT COUNT(*) AS duplicated_device_ids
FROM (SELECT device_id FROM stg_devices GROUP BY device_id HAVING COUNT(*) > 1) x;

-- Rows pointing at a warehouse that does not exist (0 expected; the
-- placeholder '99' is checked separately below)
SELECT COUNT(*) AS orphan_warehouse_rows
FROM stg_devices d
LEFT JOIN warehouses w ON d.warehouse_id = w.warehouse_id
WHERE w.warehouse_id IS NULL;

-- Blank or NULL category (62 expected)
SELECT COUNT(*) AS blank_category_rows
FROM stg_devices
WHERE category_id IS NULL OR category_id = '';

-- ---------------------------------------------------------------------
-- 4. 'Unknown' dimension rows for values that cannot be recovered
--    Run once only: re-running adds a second 'Unknown' row.
-- ---------------------------------------------------------------------
INSERT INTO warehouses (city, country, manager_name, phone, address)
VALUES ('Unknown', 'Unknown', NULL, NULL, NULL);

INSERT INTO device_categories (category_name, avg_retail_value, category_description)
VALUES ('Unknown', NULL, 'Category could not be determined during cleaning');

-- ---------------------------------------------------------------------
-- 5. Recover values from the duplicate partner of the same device
-- ---------------------------------------------------------------------
-- Blank category
UPDATE stg_devices AS t
JOIN stg_devices AS s
  ON t.device_id = s.device_id AND t.stg_row_id <> s.stg_row_id
SET t.category_id = s.category_id
WHERE (t.category_id = '' OR t.category_id IS NULL)
  AND s.category_id IS NOT NULL AND s.category_id <> '';

-- Warehouse placeholder 99
UPDATE stg_devices AS t
JOIN stg_devices AS s
  ON t.device_id = s.device_id AND t.stg_row_id <> s.stg_row_id
SET t.warehouse_id = s.warehouse_id
WHERE t.warehouse_id = '99'
  AND s.warehouse_id IS NOT NULL AND s.warehouse_id <> '' AND s.warehouse_id <> '99';

-- Blank brand
UPDATE stg_devices AS t
JOIN stg_devices AS s
  ON t.device_id = s.device_id AND t.stg_row_id <> s.stg_row_id
SET t.brand = s.brand
WHERE (t.brand IS NULL OR t.brand = '')
  AND s.brand IS NOT NULL AND s.brand <> '';

-- ---------------------------------------------------------------------
-- 6. Whatever is still unrecoverable points to the 'Unknown' rows
-- ---------------------------------------------------------------------
UPDATE stg_devices
SET warehouse_id = (SELECT warehouse_id FROM warehouses WHERE city = 'Unknown')
WHERE warehouse_id = '99';

UPDATE stg_devices
SET category_id = (SELECT category_id FROM device_categories WHERE category_name = 'Unknown')
WHERE category_id IS NULL OR category_id = '';

-- ---------------------------------------------------------------------
-- 7. Check that duplicate pairs agree, then remove one copy of each pair
-- ---------------------------------------------------------------------
-- Expected: 0 rows (every pair identical after the recovery above)
SELECT t.device_id, t.stg_row_id, s.stg_row_id
FROM stg_devices t
JOIN stg_devices s
  ON t.device_id = s.device_id AND t.stg_row_id < s.stg_row_id
WHERE t.customer_id <> s.customer_id
   OR t.intake_date <> s.intake_date
   OR t.category_id <> s.category_id
   OR t.warehouse_id <> s.warehouse_id
   OR t.brand <> s.brand
   OR t.model <> s.model
   OR t.serial_number <> s.serial_number;

-- stg_row_id is an integer, so MAX compares numbers (safe)
DELETE FROM stg_devices
WHERE stg_row_id IN (
    SELECT dup_row_to_delete
    FROM (SELECT MAX(stg_row_id) AS dup_row_to_delete
          FROM stg_devices
          GROUP BY device_id
          HAVING COUNT(*) > 1) AS a);

-- Expected: 6000
SELECT COUNT(*) AS devices_after_cleaning FROM stg_devices;

-- Remaining blank brands (about 234 expected; left for Power Query)
SELECT COUNT(*) AS blank_brand_rows
FROM stg_devices
WHERE brand IS NULL OR brand = '';

COMMIT;
