/* =====================================================================
   05_cleaning_outcomes.sql
   Cleans stg_outcomes. Run after 02_staging_load.sql.

   Problem: some sale_price values carry a currency suffix (for example
   '1250 kr'), which cannot be cast to a number. listed_price needed no
   cleaning. Blank text is turned into NULL during the production load
   (06_load_production.sql).
   ===================================================================== */

USE device_pipeline;

-- Profiling
SELECT COUNT(*) AS prices_with_kr
FROM stg_outcomes
WHERE sale_price LIKE '%kr';

SELECT DISTINCT final_status FROM stg_outcomes;

-- Preview the fix
SELECT sale_price, REPLACE(sale_price, ' kr', '') AS cleaned
FROM stg_outcomes
WHERE sale_price LIKE '%kr'
LIMIT 5;

-- Apply
UPDATE stg_outcomes
SET sale_price = REPLACE(sale_price, ' kr', '')
WHERE sale_price LIKE '%kr';

-- Check: expected 0, and a cast test on the cleaned values
SELECT COUNT(*) AS prices_with_kr_left
FROM stg_outcomes
WHERE sale_price LIKE '%kr';

SELECT sale_price, CAST(sale_price AS DECIMAL(10,2)) AS as_number
FROM stg_outcomes
WHERE sale_price IS NOT NULL AND sale_price <> ''
LIMIT 10;

COMMIT;
