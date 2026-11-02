-- =============================================================================
-- 1: SCHEMA AND TABLES
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS retail;
SET search_path TO retail;

-- Dimension tables --------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.stores (
    store_id     text PRIMARY KEY,
    county       text NOT NULL,
    tier         text NOT NULL CHECK (tier IN ('Urban', 'Peri-urban', 'Rural')),
    store_format text NOT NULL CHECK (store_format IN ('Hypermarket', 'Supermarket', 'Mini-market')),
    size_sqm     integer,
    opened_year  integer
);

CREATE TABLE IF NOT EXISTS retail.customers (
    customer_id    text PRIMARY KEY,
    county         text,
    signup_date    date,
    loyalty_tier   text CHECK (loyalty_tier IN ('Bronze', 'Silver', 'Gold')),
    age_band       text,
    household_size text,
    kids           text
);

CREATE TABLE IF NOT EXISTS retail.products (
    product_id       bigint PRIMARY KEY,
    category         text,
    product_group    text,
    product_subgroup text,
    brand            text
);

-- Staging table: raw copy of transactions.csv. No keys, because the file contains duplicate rows and blank values to be cleaned.
CREATE TABLE IF NOT EXISTS retail.stg_transactions (
    line_id         bigint,
    basket_id       bigint,
    sale_date       date,
    hour            smallint,
    store_id        text,
    customer_id     text,
    product_id      bigint,
    quantity        integer,
    unit_price_kes  numeric(14,2),
    gross_sales_kes numeric(14,2),
    discount_kes    numeric(14,2),
    net_sales_kes   numeric(14,2),
    promo_flag      smallint,
    promo_type      text,
    payment_method  text,
    payment_ref     text
);

-- Fact table: cleaned transactions ----------------------------------------
CREATE TABLE IF NOT EXISTS retail.transactions (
    line_id         bigint PRIMARY KEY,
    basket_id       bigint        NOT NULL,
    sale_date       date          NOT NULL,
    hour            smallint      CHECK (hour BETWEEN 0 AND 23),
    store_id        text          NOT NULL REFERENCES retail.stores (store_id),
    customer_id     text          REFERENCES retail.customers (customer_id), 
    product_id      bigint        NOT NULL REFERENCES retail.products (product_id),
    quantity        integer       NOT NULL CHECK (quantity > 0),
    unit_price_kes  numeric(14,2) NOT NULL CHECK (unit_price_kes > 0),
    gross_sales_kes numeric(14,2) NOT NULL,
    discount_kes    numeric(14,2) NOT NULL CHECK (discount_kes >= 0),
    net_sales_kes   numeric(14,2) NOT NULL,
    promo_flag      smallint      NOT NULL CHECK (promo_flag IN (0, 1)),
    promo_type      text          NOT NULL,
    payment_method  text          NOT NULL,
    payment_ref     text
);


-- =============================================================================
--2: LOAD THE CSV FILES
-- ============================================================================
---Stores table
COPY retail.stores (store_id, county, tier, store_format, size_sqm, opened_year) 
FROM 'C:/Users/Public/stores.csv'
WITH (FORMAT csv, HEADER true);

---transactions table
Copy retail.stg_transactions (line_id, basket_id, sale_date, hour, store_id, customer_id, product_id, quantity, unit_price_kes, gross_sales_kes, discount_kes, net_sales_kes, promo_flag, promo_type, payment_method, payment_ref)
FROM 'C:/Users/Public/transactions.csv' 
WITH (FORMAT csv, HEADER true);

---products table
copy retail.products (product_id, category, product_group, product_subgroup, brand)
FROM 'C:/Users/Public/products.csv'
WITH (FORMAT csv, HEADER true);

----customers table
copy retail.customers (customer_id, county, signup_date, loyalty_tier, age_band, household_size, kids) 
FROM 'C:/Users/Public/customers.csv' 
WITH (FORMAT csv, HEADER true);

-- =============================================================================
-- 3: DATA AUDIT (on the raw staging table, before cleaning)
-- =============================================================================
-- 3.1 Row counts: expect ~1.80M transactions, 60 stores, 2,280 customers
SELECT 'stg_transactions' AS tbl, COUNT(*) AS n FROM retail.stg_transactions
UNION ALL SELECT 'stores',    COUNT(*) FROM retail.stores
UNION ALL SELECT 'customers', COUNT(*) FROM retail.customers
UNION ALL SELECT 'products',  COUNT(*) FROM retail.products;

-- 3.2 checking duplicates: rows sharing a line_id are the same sale entered twice
SELECT COUNT(*)                    AS total_rows,
       COUNT(DISTINCT line_id)     AS distinct_lines,
       COUNT(*) - COUNT(DISTINCT line_id) AS duplicate_rows
FROM retail.stg_transactions;

-- 3.3 Missing values
SELECT COUNT(*) FILTER (WHERE customer_id    IS NULL) AS missing_customer_id,
       COUNT(*) FILTER (WHERE payment_method IS NULL) AS missing_payment_method,
       COUNT(*) FILTER (WHERE payment_ref    IS NULL) AS missing_payment_ref,   -- expected: cash/card baskets
       ROUND(100.0 * COUNT(*) FILTER (WHERE customer_id IS NULL) / COUNT(*), 1) AS pct_anonymous
FROM retail.stg_transactions;

-- 3.4 Integrity
SELECT COUNT(*) FILTER (WHERE ABS(t.gross_sales_kes - t.discount_kes - t.net_sales_kes) > 1) AS net_not_gross_minus_disc,
       COUNT(*) FILTER (WHERE t.quantity <= 0)            AS bad_quantity,
       COUNT(*) FILTER (WHERE t.unit_price_kes <= 0)      AS bad_price,
       COUNT(*) FILTER (WHERE t.hour NOT BETWEEN 0 AND 23) AS bad_hour,
       COUNT(*) FILTER (WHERE s.store_id   IS NULL)       AS unknown_stores,
       COUNT(*) FILTER (WHERE p.product_id IS NULL)       AS unknown_products,
       COUNT(*) FILTER (WHERE t.customer_id IS NOT NULL
                          AND c.customer_id IS NULL)      AS unknown_customers
FROM retail.stg_transactions t
LEFT JOIN retail.stores    s ON s.store_id    = t.store_id
LEFT JOIN retail.products  p ON p.product_id  = t.product_id
LEFT JOIN retail.customers c ON c.customer_id = t.customer_id;

-- 3.5 Date range and categorical values
SELECT MIN(sale_date) AS first_day, MAX(sale_date) AS last_day FROM retail.stg_transactions;
SELECT payment_method, COUNT(*) FROM retail.stg_transactions GROUP BY 1 ORDER BY 2 DESC;
SELECT promo_type,     COUNT(*) FROM retail.stg_transactions GROUP BY 1 ORDER BY 2 DESC;


-- =============================================================================
-- PART 4: CLEANING AND LOADING THE FACT TABLE
-- =============================================================================
TRUNCATE retail.transactions;

ALTER TABLE retail.transactions DROP CONSTRAINT transactions_discount_kes_check;

INSERT INTO retail.transactions
SELECT DISTINCT ON (line_id)
       line_id, basket_id, sale_date, hour, store_id, customer_id, product_id,
       quantity, unit_price_kes, gross_sales_kes, discount_kes, net_sales_kes,
       promo_flag, promo_type,
       COALESCE(payment_method, 'Unknown'),
       payment_ref
FROM retail.stg_transactions
ORDER BY line_id, payment_method NULLS LAST;

-- Checking rows
SELECT COUNT(*) AS clean_rows FROM retail.transactions;

-- Indexes and statistics
CREATE INDEX IF NOT EXISTS idx_tx_date     ON retail.transactions (sale_date);
CREATE INDEX IF NOT EXISTS idx_tx_store    ON retail.transactions (store_id);
CREATE INDEX IF NOT EXISTS idx_tx_customer ON retail.transactions (customer_id);
CREATE INDEX IF NOT EXISTS idx_tx_product  ON retail.transactions (product_id);
CREATE INDEX IF NOT EXISTS idx_tx_basket   ON retail.transactions (basket_id);
ANALYZE retail.transactions;

DROP TABLE retail.stg_transactions;


-- =============================================================================
-- PART 5: ANALYSING THE VIEWS
-- =============================================================================
-- One wide view with everything joined
CREATE OR REPLACE VIEW retail.v_sales AS
SELECT t.*,
       s.county                                  AS store_county,
       s.tier                                    AS store_tier,
       s.store_format,
       p.category,
       p.product_group,
       c.county                                  AS customer_county,
       c.loyalty_tier,
       date_trunc('week',  t.sale_date)::date    AS week_start,
       date_trunc('month', t.sale_date)::date    AS month_start,
       to_char(t.sale_date, 'FMDay')             AS weekday,
       EXTRACT(ISODOW FROM t.sale_date)::int     AS iso_dow
FROM retail.transactions t
JOIN retail.stores   s ON s.store_id   = t.store_id
JOIN retail.products p ON p.product_id = t.product_id
LEFT JOIN retail.customers c ON c.customer_id = t.customer_id;

-- Product x store x week summary, used for promotion lift
DROP MATERIALIZED VIEW IF EXISTS retail.mv_product_store_week CASCADE;
CREATE MATERIALIZED VIEW retail.mv_product_store_week AS
SELECT product_id,
       store_id,
       date_trunc('week', sale_date)::date                              AS week_start,
       SUM(quantity)                                                    AS units,
       COALESCE(SUM(quantity) FILTER (WHERE promo_flag = 1), 0)         AS promo_units,
       SUM(net_sales_kes)                                               AS revenue,
       SUM(gross_sales_kes)                                             AS gross,
       SUM(discount_kes)                                                AS disc
FROM retail.transactions
GROUP BY product_id, store_id, date_trunc('week', sale_date)::date;

CREATE INDEX ON retail.mv_product_store_week (product_id, store_id);

-- Cleaning promo weeks: >= 80% of units sold on promo, compared with that
-- product's non-promo weeks in the same store (min 3 base weeks, >= 5 units/week)
CREATE OR REPLACE VIEW retail.v_promo_weeks AS
WITH base AS (
    SELECT product_id, store_id,
           AVG(units)   AS base_units,
           AVG(revenue) AS base_rev,
           COUNT(*)     AS base_weeks
    FROM retail.mv_product_store_week
    WHERE promo_units = 0
    GROUP BY product_id, store_id
)
SELECT m.product_id, m.store_id, m.week_start, p.category,
       m.units, m.revenue, b.base_units, b.base_rev,
       m.units   / b.base_units  AS unit_lift,
       m.revenue / b.base_rev    AS rev_lift,
       m.disc / NULLIF(m.gross, 0) AS disc_pct,
       CASE WHEN m.disc / NULLIF(m.gross, 0) <= 0.25 THEN '1: <25%'
            WHEN m.disc / NULLIF(m.gross, 0) <= 0.35 THEN '2: 25-35%'
            WHEN m.disc / NULLIF(m.gross, 0) <= 0.45 THEN '3: 35-45%'
            ELSE                                          '4: 45%+' END AS depth
FROM retail.mv_product_store_week m
JOIN base b USING (product_id, store_id)
JOIN retail.products p ON p.product_id = m.product_id
WHERE m.promo_units::numeric / m.units >= 0.8
  AND b.base_weeks >= 3
  AND b.base_units >= 5;

-- RFM scores
CREATE OR REPLACE VIEW retail.v_rfm AS
WITH snap AS (SELECT MAX(sale_date) + 1 AS snapshot FROM retail.transactions),
rfm AS (
    SELECT t.customer_id,
           (snap.snapshot - MAX(t.sale_date))  AS recency_days,
           COUNT(DISTINCT t.basket_id)         AS frequency,
           SUM(t.net_sales_kes)                AS monetary
    FROM retail.transactions t CROSS JOIN snap
    WHERE t.customer_id IS NOT NULL
    GROUP BY t.customer_id, snap.snapshot
),
scored AS (
    SELECT *,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,  -- 5 = most recent
           NTILE(5) OVER (ORDER BY frequency)         AS f_score,
           NTILE(5) OVER (ORDER BY monetary)          AS m_score
    FROM rfm
)
SELECT *,
       CASE WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
            WHEN r_score <= 2 AND m_score >= 4                  THEN 'At-risk high value'
            WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal regulars'
            WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lapsed'
            ELSE 'Needs attention' END AS segment
FROM scored;


-- =============================================================================
-- PART 6: ANALYSING QUERIES
-- =============================================================================

-- ---- Objective 1: what drives revenue? (county, format, category) ---------
-- County results reflect which stores were randomly assigned
SELECT store_county,
       ROUND(SUM(net_sales_kes))                                   AS net_sales_kes,
       COUNT(DISTINCT store_id)                                    AS stores,
       ROUND(SUM(net_sales_kes) / COUNT(DISTINCT store_id))        AS sales_per_store,
       ROUND(SUM(net_sales_kes) / COUNT(DISTINCT basket_id))       AS avg_basket_kes
FROM retail.v_sales
GROUP BY store_county
ORDER BY net_sales_kes DESC;

-- Fair comparison of formats per store
SELECT store_format,
       COUNT(DISTINCT store_id)                                    AS stores,
       ROUND(SUM(net_sales_kes))                                   AS net_sales_kes,
       ROUND(SUM(net_sales_kes) / COUNT(DISTINCT store_id))        AS sales_per_store,
       ROUND(SUM(net_sales_kes) / COUNT(DISTINCT basket_id))       AS avg_basket_kes
FROM retail.v_sales
GROUP BY store_format
ORDER BY sales_per_store DESC;

-- Categories with share of total
SELECT category,
       ROUND(SUM(net_sales_kes))                                          AS net_sales_kes,
       ROUND(100 * SUM(net_sales_kes) / SUM(SUM(net_sales_kes)) OVER (), 1) AS pct_of_sales,
       SUM(quantity)                                                      AS units
FROM retail.v_sales
GROUP BY category
ORDER BY net_sales_kes DESC
LIMIT 10;

-- ---- Objective 2: trends and weekday pattern -------------------------------
-- Monthly sales with month-over-month change. December 2025 is partial.
-- Note the first months ramp up as panel households become active (artifact).
SELECT month_start,
       ROUND(SUM(net_sales_kes))                                    AS net_sales_kes,
       ROUND(100 * (SUM(net_sales_kes)
             / LAG(SUM(net_sales_kes)) OVER (ORDER BY month_start) - 1), 1) AS mom_pct
FROM retail.v_sales
WHERE sale_date < DATE '2025-12-01'
GROUP BY month_start
ORDER BY month_start;

-- Average DAILY sales by weekday (averaging per day avoids calendar bias)
WITH daily AS (
    SELECT sale_date, SUM(net_sales_kes) AS sales
    FROM retail.transactions
    GROUP BY sale_date
)
SELECT to_char(sale_date, 'FMDay')        AS weekday,
       EXTRACT(ISODOW FROM sale_date)::int AS iso_dow,
       COUNT(*)                            AS days,
       ROUND(AVG(sales))                   AS avg_daily_sales
FROM daily
GROUP BY 1, 2
ORDER BY iso_dow;

-- Sales by hour of day
SELECT hour, ROUND(SUM(net_sales_kes)) AS net_sales_kes, COUNT(DISTINCT basket_id) AS baskets
FROM retail.transactions
GROUP BY hour
ORDER BY hour;

-- ---- Objectives 3-5: promotions -------------------------------------------
-- Share of lines on promotion (promo = discount >= 25% in the build script)
SELECT ROUND(100.0 * AVG(promo_flag), 1) AS pct_lines_on_promo FROM retail.transactions;

-- Lift by discount depth (totals, not medians of ratios)
SELECT depth,
       COUNT(*)                                   AS promo_weeks,
       ROUND(SUM(units) / SUM(base_units), 2)     AS unit_lift,
       ROUND(SUM(revenue) / SUM(base_rev), 2)     AS rev_lift
FROM retail.v_promo_weeks
GROUP BY depth
ORDER BY depth;

-- Lift by category
SELECT category,
       COUNT(*)                                   AS promo_weeks,
       ROUND(SUM(units) / SUM(base_units), 2)     AS unit_lift,
       ROUND(SUM(revenue) / SUM(base_rev), 2)     AS rev_lift
FROM retail.v_promo_weeks
GROUP BY category
HAVING COUNT(*) >= 30
ORDER BY rev_lift DESC;

-- Failing promotions: promo weeks that earned less revenue than a normal week
SELECT category,
       COUNT(*)                                                     AS promo_weeks,
       ROUND(100.0 * AVG((rev_lift < 1)::int), 1)                   AS pct_failing
FROM retail.v_promo_weeks
GROUP BY category
HAVING COUNT(*) >= 30
ORDER BY pct_failing DESC;

-- ---- Objectives 6-7: RFM segments -----------------------------------------
SELECT segment,
       COUNT(*)                                                      AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)            AS pct_customers,
       ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY recency_days)::numeric) AS median_recency_days,
       ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY frequency)::numeric)    AS median_baskets,
       ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY monetary)::numeric)     AS median_spend_kes,
       ROUND(100 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1)    AS pct_of_spend
FROM retail.v_rfm
GROUP BY segment
ORDER BY median_spend_kes DESC;

-- What each segment buys: top 3 categories per segment
WITH seg_cat AS (
    SELECT r.segment, v.category, SUM(v.net_sales_kes) AS sales
    FROM retail.v_sales v
    JOIN retail.v_rfm r ON r.customer_id = v.customer_id
    GROUP BY r.segment, v.category
),
ranked AS (
    SELECT segment, category,
           ROUND(100 * sales / SUM(sales) OVER (PARTITION BY segment), 1) AS pct_of_segment_spend,
           ROW_NUMBER() OVER (PARTITION BY segment ORDER BY sales DESC)   AS rnk
    FROM seg_cat
)
SELECT segment, category, pct_of_segment_spend
FROM ranked
WHERE rnk <= 3
ORDER BY segment, rnk;

-- ---- Objectives 8-9: weekly category forecast baselines ---------------------
-- Test window = last 12 FULL weeks. Naive = same as last week; seasonal naive =
-- same week last year (52 weeks earlier). Top 8 categories by sales.
WITH full_weeks AS (
    SELECT date_trunc('week', sale_date)::date AS week_start
    FROM retail.transactions
    GROUP BY 1
    HAVING COUNT(DISTINCT sale_date) = 7
),
wk AS (
    SELECT w.week_start, p.category, SUM(t.net_sales_kes) AS sales
    FROM retail.transactions t
    JOIN retail.products p ON p.product_id = t.product_id
    JOIN full_weeks w ON w.week_start = date_trunc('week', t.sale_date)::date
    GROUP BY w.week_start, p.category
),
top_cats AS (
    SELECT category FROM wk GROUP BY category ORDER BY SUM(sales) DESC LIMIT 8
),
cutoff AS (
    SELECT week_start AS first_test_week
    FROM full_weeks ORDER BY week_start DESC OFFSET 11 LIMIT 1
)
SELECT a.category,
       COUNT(*)                                                         AS test_weeks,
       ROUND(100 * AVG(ABS(a.sales - b.sales) / a.sales), 1)            AS naive_mape,
       ROUND(100 * AVG(ABS(a.sales - c.sales) / a.sales), 1)            AS seasonal_naive_mape
FROM wk a
JOIN cutoff ON a.week_start >= cutoff.first_test_week
JOIN top_cats USING (category)
JOIN wk b ON b.category = a.category AND b.week_start = a.week_start - 7
LEFT JOIN wk c ON c.category = a.category AND c.week_start = a.week_start - 364
GROUP BY a.category
ORDER BY a.category;

-- ---- Statistical summaries in SQL ------------------------------------------
-- Basket value distribution (skewed: median << mean)
WITH basket AS (
    SELECT basket_id, SUM(net_sales_kes) AS total
    FROM retail.transactions
    GROUP BY basket_id
)
SELECT COUNT(*)                                                          AS baskets,
       ROUND(AVG(total))                                                 AS mean_kes,
       ROUND(percentile_cont(0.25) WITHIN GROUP (ORDER BY total)::numeric) AS p25,
       ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY total)::numeric) AS median,
       ROUND(percentile_cont(0.75) WITHIN GROUP (ORDER BY total)::numeric) AS p75,
       ROUND(percentile_cont(0.95) WITHIN GROUP (ORDER BY total)::numeric) AS p95,
       ROUND(STDDEV_SAMP(total))                                         AS std_kes
FROM basket;

-- Correlation between discount depth and unit lift (clean promo weeks)
SELECT COUNT(*)                         AS promo_weeks,
       ROUND(corr(disc_pct, unit_lift)::numeric, 3) AS pearson_depth_vs_unit_lift
FROM retail.v_promo_weeks;

-- Payment mix by store tier. NOTE: payment methods are simulated, so this
-- reports how the simulation behaves, not real customer behaviour.
SELECT store_tier,
       ROUND(100.0 * AVG((payment_method = 'M-Pesa')::int), 1) AS pct_mpesa,
       ROUND(100.0 * AVG((payment_method = 'Cash')::int), 1)   AS pct_cash,
       ROUND(100.0 * AVG((payment_method = 'Card')::int), 1)   AS pct_card
FROM (SELECT DISTINCT ON (t.basket_id) t.basket_id, s.tier AS store_tier, t.payment_method
      FROM retail.transactions t
      JOIN retail.stores s ON s.store_id = t.store_id
      ORDER BY t.basket_id) b
GROUP BY store_tier;

