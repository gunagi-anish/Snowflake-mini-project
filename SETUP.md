# Setup Guide

This guide takes you from nothing to a working Snowflake project. It assumes you have never used Snowflake. Expect it to take about 45 minutes.

## What you need

- A web browser
- A Snowflake account (the free trial is enough)
- The files in this folder: [`orders.csv`](orders.csv) and [`sales_project.sql`](sales_project.sql)
- Python 3 (only if you want to regenerate the data, which is optional)

## How to work through this guide

All SQL is in [`sales_project.sql`](sales_project.sql). Copy one block at a time into a Snowsight worksheet, select it, and press **Ctrl+Enter** to run it.

> **Do not use "Run All".** The script uses `CREATE OR REPLACE`, which would wipe objects you have already built, including loaded data.

> **Run the `USE` lines first in any new worksheet.** Each worksheet starts with its own default database, which causes errors like `Schema 'XYZ.ANALYTICS' does not exist`. See Troubleshooting.

---

## Step 0: Create an account and open a worksheet

1. Sign up for a free trial at <https://signup.snowflake.com>. Choose the **Standard** edition.
2. Log in to **Snowsight**, the web interface.
3. Open a SQL worksheet. Depending on your version, this is under **Projects → Worksheets** or **Projects → Workspaces**, then **+ SQL file**.

## Step 1: Get the data

Use the included [`orders.csv`](orders.csv). To regenerate it:

```
python generate_data.py
```

This writes 5,000 rows to `orders.csv`. The random seed is fixed, so you always get the same data.

## Step 2: Create the warehouse, database and schemas

Run these blocks one at a time.

```sql
USE ROLE ACCOUNTADMIN;
```

```sql
CREATE WAREHOUSE IF NOT EXISTS learn_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE;
```

```sql
CREATE DATABASE IF NOT EXISTS sales_db;
CREATE SCHEMA   IF NOT EXISTS sales_db.raw;
CREATE SCHEMA   IF NOT EXISTS sales_db.analytics;
```

```sql
USE WAREHOUSE learn_wh;
USE DATABASE  sales_db;
USE SCHEMA    sales_db.raw;
```

**Check:**
```sql
SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
```
Expected: `ACCOUNTADMIN | LEARN_WH | SALES_DB | RAW`

## Step 3: Create the file format, stage and table

```sql
CREATE OR REPLACE FILE FORMAT csv_fmt
  TYPE = 'CSV'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';
```

```sql
CREATE OR REPLACE STAGE my_stage FILE_FORMAT = csv_fmt;
```

```sql
CREATE OR REPLACE TABLE orders (
  order_id   STRING,
  order_date DATE,
  customer   STRING,
  category   STRING,
  region     STRING,
  sales      NUMBER(12,2),
  profit     NUMBER(12,2)
);
```

**Check:** `SHOW FILE FORMATS;`, `SHOW STAGES;` and `DESC TABLE orders;` should show `CSV_FMT`, `MY_STAGE` and 7 columns.

## Step 4: Upload `orders.csv` to the stage

The menu location differs between Snowsight versions. Try these in order:

1. In the Database Explorer, expand **SALES_DB → RAW → Stages**, hover over **MY_STAGE**, click **⋯**, and choose a **Load files** or **Add files** option.
2. Or use the **+** icon in the far-left bar, then **Add Data → Load files into a Stage**. Select `SALES_DB`, `RAW` and `MY_STAGE`.
3. Choose `orders.csv` and upload.

**Check:**
```sql
LIST @my_stage;
```
You should see `orders.csv.gz`. Snowflake compresses uploads automatically, which is normal.

## Step 5: Load the data

```sql
COPY INTO orders
FROM @my_stage
ON_ERROR = 'ABORT_STATEMENT';
```

**Check:**
```sql
SELECT COUNT(*) FROM orders;   -- expect 5000
```

Run `COPY INTO` only once. Snowflake remembers loaded files, so a second run loads 0 rows. To reload, run `TRUNCATE TABLE orders;` first, then `COPY INTO` again.

## Step 6: Clean and transform with views

```sql
USE SCHEMA sales_db.analytics;
```

```sql
CREATE OR REPLACE VIEW clean_orders AS
SELECT DISTINCT
       order_id,
       order_date,
       TRIM(customer) AS customer,
       category,
       region,
       sales,
       profit
FROM sales_db.raw.orders
WHERE sales > 0
  AND order_date IS NOT NULL;
```

```sql
CREATE OR REPLACE VIEW monthly_sales AS
SELECT DATE_TRUNC('month', order_date) AS month,
       region,
       category,
       SUM(sales)  AS total_sales,
       SUM(profit) AS total_profit
FROM clean_orders
GROUP BY 1, 2, 3;
```

**Check:** `SELECT COUNT(*) FROM clean_orders;` returns about 5000.

## Step 7: Run the analysis queries

Make sure you are in `sales_db.analytics`.

**A. Top 10 customers by revenue**
```sql
SELECT customer, ROUND(SUM(sales), 2) AS revenue
FROM clean_orders
GROUP BY customer
ORDER BY revenue DESC
LIMIT 10;
```

**B. Month-over-month growth**
```sql
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
```

**C. Most profitable category per region**
```sql
SELECT region, category, total_profit
FROM (
  SELECT region, category, ROUND(SUM(profit), 2) AS total_profit,
         RANK() OVER (PARTITION BY region ORDER BY SUM(profit) DESC) AS rnk
  FROM clean_orders
  GROUP BY region, category
)
WHERE rnk = 1
ORDER BY region;
```

Expected: A returns 10 rows, B returns 24 rows (the first has NULL growth), and C returns 4 rows, one per region.

## Step 8: Visualize

### Quick option: the Chart tab
Run any query above, then click **Chart** next to **Table** in the results panel. Bar charts suit A and C, and a line chart suits B.

### Dashboard option: Streamlit
Avoid **Legacy Dashboards**, which is deprecated.

1. Go to **Projects → Streamlit** and create an app.
2. Set the location to `SALES_DB.ANALYTICS` and the warehouse to `LEARN_WH`.
3. Replace the sample code with:

```python
import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.title("Sales Overview")

st.subheader("Top 10 customers by revenue")
top_customers = session.sql("""
    SELECT customer, ROUND(SUM(sales), 2) AS revenue
    FROM sales_db.analytics.clean_orders
    GROUP BY customer
    ORDER BY revenue DESC
    LIMIT 10
""").to_pandas()
st.bar_chart(top_customers, x="CUSTOMER", y="REVENUE")

st.subheader("Monthly sales trend")
monthly = session.sql("""
    SELECT month, ROUND(SUM(total_sales), 2) AS sales
    FROM sales_db.analytics.monthly_sales
    GROUP BY month
    ORDER BY month
""").to_pandas()
st.line_chart(monthly, x="MONTH", y="SALES")

st.subheader("Sales by region")
regions = session.sql("""
    SELECT region, ROUND(SUM(sales), 2) AS sales
    FROM sales_db.analytics.clean_orders
    GROUP BY region
    ORDER BY sales DESC
""").to_pandas()
st.bar_chart(regions, x="REGION", y="SALES")
```

Column names are uppercase because Snowflake stores unquoted names that way.

## Step 9 (optional): Clone, Time Travel and a task

### Clone
```sql
USE SCHEMA sales_db.raw;
CREATE OR REPLACE TABLE orders_backup CLONE orders;
SELECT COUNT(*) FROM orders_backup;   -- 5000
```

### Time Travel
Run these in order, one at a time.
```sql
DELETE FROM orders WHERE region = 'East';
SET del_id = LAST_QUERY_ID();    -- run immediately after the DELETE
SELECT COUNT(*) FROM orders;                                   -- fewer rows
SELECT COUNT(*) FROM orders BEFORE(STATEMENT => $del_id);      -- 5000
INSERT INTO orders
SELECT * FROM orders BEFORE(STATEMENT => $del_id) WHERE region = 'East';
SELECT COUNT(*) FROM orders;                                   -- 5000 again
```
If the variable fails, copy the DELETE's query ID from Query History and use `BEFORE(STATEMENT => 'the-id')`. Or restore from the clone: `INSERT INTO orders SELECT * FROM orders_backup WHERE region = 'East';`

### Scheduled task
```sql
USE SCHEMA sales_db.analytics;

CREATE OR REPLACE TABLE daily_summary (run_date DATE, total_sales NUMBER(14,2));

CREATE OR REPLACE TASK refresh_summary
  WAREHOUSE = learn_wh
  SCHEDULE  = 'USING CRON 0 2 * * * UTC'
AS
  INSERT INTO daily_summary
  SELECT CURRENT_DATE(), SUM(sales) FROM clean_orders;

EXECUTE TASK refresh_summary;
SELECT * FROM daily_summary;
ALTER TASK refresh_summary SUSPEND;
```
Keep the task suspended. A resumed task wakes the warehouse every day and uses credits.

## Step 10: Clean up

```sql
ALTER TASK sales_db.analytics.refresh_summary SUSPEND;
ALTER WAREHOUSE learn_wh SUSPEND;
```

To delete the whole project:
```sql
DROP DATABASE sales_db;
DROP WAREHOUSE learn_wh;
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Schema 'OUR_FIRST_DB.ANALYTICS' does not exist` | The worksheet is pointing at another database | Run `USE DATABASE sales_db;` and `USE SCHEMA sales_db.raw;` |
| `Insufficient privileges` | Wrong role | Run `USE ROLE ACCOUNTADMIN;` |
| `No active warehouse` | Warehouse not selected | Run `USE WAREHOUSE learn_wh;` |
| `LIST @my_stage;` is empty | Upload did not finish, or the wrong stage was used | Re-upload to `SALES_DB.RAW.MY_STAGE` |
| `COPY INTO` loads 0 rows | The file was already loaded | `TRUNCATE TABLE orders;` then reload |
| Date or number parse error on load | Header row not skipped | Re-create `csv_fmt` with `SKIP_HEADER = 1`, truncate, reload |
| `Object CLEAN_ORDERS does not exist` | Wrong schema | Run `USE SCHEMA sales_db.analytics;` |
| `KeyError: 'customer'` in Streamlit | Column names are uppercase | Use `"CUSTOMER"`, `"REVENUE"` and so on |
| Chart tab is greyed out | No results yet | Run the query first |
| Query B syntax error | Only part of the query was selected | Select the whole query, `WITH` to `ORDER BY month;` |

## Cost safety checklist

- The warehouse is `XSMALL` with `AUTO_SUSPEND = 60`.
- The task `refresh_summary` is suspended.
- You ran `ALTER WAREHOUSE learn_wh SUSPEND;` when you finished.
