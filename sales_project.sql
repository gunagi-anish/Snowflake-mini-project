-- =====================================================================
-- Snowflake Beginner Project: Retail Sales Analytics
-- Run each section in a Snowsight worksheet, top to bottom.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1: SETUP
-- ---------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS learn_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS sales_db;
CREATE SCHEMA   IF NOT EXISTS sales_db.raw;
CREATE SCHEMA   IF NOT EXISTS sales_db.analytics;

USE WAREHOUSE learn_wh;
USE DATABASE  sales_db;
USE SCHEMA    sales_db.raw;

-- ---------------------------------------------------------------------
-- STEP 2: FILE FORMAT, STAGE, TABLE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT csv_fmt
  TYPE = 'CSV'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';

CREATE OR REPLACE STAGE my_stage FILE_FORMAT = csv_fmt;

CREATE OR REPLACE TABLE orders (
  order_id   STRING,
  order_date DATE,
  customer   STRING,
  category   STRING,
  region     STRING,
  sales      NUMBER(12,2),
  profit     NUMBER(12,2)
);

-- ---------------------------------------------------------------------
-- STEP 3: UPLOAD orders.csv TO THE STAGE
-- Option A (Snowsight UI): Data > Databases > SALES_DB > RAW > Stages
--         > MY_STAGE > "+ Files" > choose orders.csv
-- Option B (SnowSQL CLI):  PUT file://C:/path/to/orders.csv @my_stage;
-- ---------------------------------------------------------------------
LIST @my_stage;   -- should show orders.csv

-- ---------------------------------------------------------------------
-- STEP 4: LOAD
-- ---------------------------------------------------------------------
COPY INTO orders FROM @my_stage ON_ERROR = 'ABORT_STATEMENT';

SELECT COUNT(*) FROM orders;        -- expect 5000
SELECT * FROM orders LIMIT 10;

-- ---------------------------------------------------------------------
-- STEP 5: CLEAN + TRANSFORM
-- ---------------------------------------------------------------------
USE SCHEMA analytics;

CREATE OR REPLACE VIEW clean_orders AS
SELECT DISTINCT
       order_id,
       order_date,
       TRIM(customer)  AS customer,
       category,
       region,
       sales,
       profit
FROM raw.orders
WHERE sales > 0 AND order_date IS NOT NULL;

CREATE OR REPLACE VIEW monthly_sales AS
SELECT DATE_TRUNC('month', order_date) AS month,
       region,
       category,
       SUM(sales)  AS total_sales,
       SUM(profit) AS total_profit
FROM clean_orders
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- STEP 6: ANALYSIS QUERIES
-- ---------------------------------------------------------------------

-- 6a. Top 10 customers by revenue
SELECT customer, ROUND(SUM(sales), 2) AS revenue
FROM clean_orders
GROUP BY customer
ORDER BY revenue DESC
LIMIT 10;

-- 6b. Month-over-month growth (LAG)
WITH m AS (
  SELECT DATE_TRUNC('month', order_date) AS month, SUM(sales) AS sales
  FROM clean_orders
  GROUP BY 1
)
SELECT month,
       ROUND(sales, 2) AS sales,
       ROUND(LAG(sales) OVER (ORDER BY month), 2) AS prev_month,
       ROUND((sales - LAG(sales) OVER (ORDER BY month))
             / NULLIF(LAG(sales) OVER (ORDER BY month), 0) * 100, 1) AS growth_pct
FROM m
ORDER BY month;

-- 6c. Most profitable category in each region (RANK)
SELECT region, category, total_profit
FROM (
  SELECT region, category, SUM(profit) AS total_profit,
         RANK() OVER (PARTITION BY region ORDER BY SUM(profit) DESC) AS rnk
  FROM clean_orders
  GROUP BY region, category
)
WHERE rnk = 1
ORDER BY region;

-- ---------------------------------------------------------------------
-- STEP 7: VISUALIZE
-- Run any query above > click "Chart" tab under results.
-- Then: Projects > Dashboards > "+ Dashboard" and add tiles.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- STEP 8 (OPTIONAL): TIME TRAVEL, CLONE, TASK
-- ---------------------------------------------------------------------
-- Zero-copy clone (instant backup)
CREATE OR REPLACE TABLE raw.orders_backup CLONE raw.orders;

-- Time Travel: delete rows "by accident", then recover them
DELETE FROM raw.orders WHERE region = 'East';
SELECT COUNT(*) FROM raw.orders;                       -- fewer rows now
SELECT COUNT(*) FROM raw.orders AT(OFFSET => -60);     -- before delete (60 sec ago)
-- Restore (get the query_id of the DELETE from Query History):
-- INSERT INTO raw.orders SELECT * FROM raw.orders BEFORE(STATEMENT => '<delete_query_id>') WHERE region = 'East';
-- Or simply: INSERT INTO raw.orders SELECT * FROM raw.orders_backup WHERE region = 'East';

-- Scheduled task: nightly summary table refresh
CREATE OR REPLACE TABLE analytics.daily_summary (run_date DATE, total_sales NUMBER(14,2));

CREATE OR REPLACE TASK analytics.refresh_summary
  WAREHOUSE = learn_wh
  SCHEDULE  = 'USING CRON 0 2 * * * UTC'
AS
  INSERT INTO analytics.daily_summary
  SELECT CURRENT_DATE(), SUM(sales) FROM analytics.clean_orders;

ALTER TASK analytics.refresh_summary RESUME;
-- IMPORTANT: suspend when done learning so it stops using credits
ALTER TASK analytics.refresh_summary SUSPEND;

-- ---------------------------------------------------------------------
-- STEP 9: CLEAN UP (save credits)
-- ---------------------------------------------------------------------
ALTER WAREHOUSE learn_wh SUSPEND;
-- DROP DATABASE sales_db;   -- only when you want to delete everything
-- DROP WAREHOUSE learn_wh;
