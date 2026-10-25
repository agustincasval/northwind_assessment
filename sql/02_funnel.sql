-- =====================================================================
-- 02_funnel.sql — Funnel metrics on the cleaned data
-- Snowflake SQL (also runs in DuckDB). Run after 01_clean.sql.
-- Win = paying deal (amount > $0) closed within 30 days of signup.
--
-- WHAT WE HAD TO FIX SO THE DATA IS USABLE
-- (applied in 01_clean.sql; 02 and 03 only read the cleaned tables)
--
-- | Rule | Table         | Problem found                               | What we did                         | Rows   |
-- |------|---------------|---------------------------------------------|-------------------------------------|--------|
-- | R1   | sessions      | Same channel written 12 ways ("direct ")    | Map to 7 channel names              | 1,284  |
-- | R2   | sessions      | 135 URL spellings of ~20 pages              | Clean URL, group into 7 page types  | all    |
-- | R3   | sessions      | Visit with no visitor id                    | Keep, mark is_visitor_missing       | 300    |
-- | R4   | signups       | Exact duplicate rows                        | Remove                              | 66     |
-- | R5   | signups       | Fake company sizes (-5, 999,999)            | Set to unknown                      | 30     |
-- | R6   | signups       | Same lead twice with different details      | Keep the most complete row          | 4 leads|
-- | R7   | signups       | Signup dated July, after the data ends      | Use the date of its visit           | 8      |
-- | R8   | signups       | Points to a visit that doesn't exist        | Keep, mark is_session_orphan        | 25     |
-- | R9   | opportunities | Exact duplicate rows                        | Remove                              | 18     |
-- | R10  | opportunities | Amount 1,000x the price (35,000 / 110,000)  | Divide by 1,000                     | 6      |
-- | R11  | opportunities | $0 deals (nobody pays)                      | Keep, mark is_zero_amount; not wins | 30     |
-- | R12  | opportunities | Negative days_to_close (sign bug)           | Recompute from the dates            | 10     |
-- | R13  | opportunities | Points to a lead that doesn't exist         | Keep, mark is_lead_orphan           | 15     |
-- | R14  | signups       | Country written as the text 'N/A'           | Set to unknown                      | 25     |
--
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1. monthly_funnel — the whole funnel by signup month
-- visits -> signups -> paying customers -> deal value
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE monthly_funnel AS
WITH visits_by_month AS (
    SELECT CAST(DATE_TRUNC('month', event_dt) AS DATE) AS month,
           COUNT(*) AS sessions
    FROM sessions_clean
    GROUP BY 1
),
signups_by_month AS (
    SELECT signup_month AS month,
           COUNT(*)                     AS signups,
           SUM(is_win)                  AS wins_30d,          -- is_win is 1/0, so SUM counts wins
           SUM(is_win * won_amount)     AS deal_value_30d     -- amount only counts for wins
    FROM signup_outcomes
    GROUP BY 1
)
SELECT
    month,
    sessions,
    signups,
    wins_30d,
    deal_value_30d,
    ROUND(100.0 * signups  / sessions, 2) AS sess_to_signup_pct,
    ROUND(100.0 * wins_30d / signups, 1)  AS signup_to_win_pct,
    ROUND(100.0 * wins_30d / sessions, 2) AS sess_to_win_pct
FROM visits_by_month
JOIN signups_by_month USING (month)
ORDER BY month;


-- ---------------------------------------------------------------------
-- STEP 2. weekly_funnel — same idea, by week (weeks start on Monday)
-- Only full 7-day weeks: Jan 1-4 and Jun 29-30 are cut off.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE weekly_funnel AS
SELECT
    CAST(DATE_TRUNC('week', created_dt) AS DATE)             AS week_start,
    COUNT(*)                                                 AS signups,
    SUM(CASE WHEN product = 'Free CRM' THEN 1 ELSE 0 END)    AS free_crm_signups,
    SUM(is_win)                                              AS wins_30d,
    ROUND(100.0 * AVG(is_win), 1)                            AS signup_to_win_pct   -- average of 1/0 = conversion rate
FROM signup_outcomes
GROUP BY 1
HAVING MAX(created_dt) - MIN(created_dt) = 6                 -- Monday to Sunday = 6 days apart
ORDER BY 1;


-- ---------------------------------------------------------------------
-- STEP 3. product_funnel — the funnel split by SKU, per month
-- mix_pct = this SKU's share of the month's signups
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE product_funnel AS
SELECT
    signup_month AS month,
    product,
    COUNT(*)                                     AS signups,
    -- window function: divide by the total signups of the same month
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY signup_month), 1) AS mix_pct,
    SUM(is_win)                                  AS wins_30d,
    ROUND(100.0 * AVG(is_win), 1)                AS signup_to_win_pct,
    SUM(is_win * won_amount)                     AS deal_value_30d
FROM signup_outcomes
GROUP BY signup_month, product
ORDER BY month, product;


-- ---------------------------------------------------------------------
-- STEP 4. slice_conversion — conversion for every origin slice
-- Trick: stack the table 6 times (one per dimension) with UNION ALL,
-- so a single GROUP BY gives every slice at once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE slice_conversion AS
WITH stacked AS (
    SELECT signup_month, period, is_win, product, 'channel'      AS dimension, mktg_channel        AS value FROM signup_outcomes
    UNION ALL
    SELECT signup_month, period, is_win, product, 'entry_page'   AS dimension, page_type           AS value FROM signup_outcomes
    UNION ALL
    SELECT signup_month, period, is_win, product, 'device'       AS dimension, device_type         AS value FROM signup_outcomes
    UNION ALL
    SELECT signup_month, period, is_win, product, 'visitor_type' AS dimension, visitor_type        AS value FROM signup_outcomes
    UNION ALL
    SELECT signup_month, period, is_win, product, 'company_size' AS dimension, company_size_bucket AS value FROM signup_outcomes
    UNION ALL
    SELECT signup_month, period, is_win, product, 'geo'          AS dimension, COALESCE(geo, 'Unknown') AS value FROM signup_outcomes
)
SELECT
    dimension,
    value,
    signup_month AS month,
    period,
    COUNT(*)                                                           AS signups,
    SUM(is_win)                                                        AS wins_30d,
    ROUND(100.0 * AVG(is_win), 1)                                      AS signup_to_win_pct,
    ROUND(100.0 * AVG(CASE WHEN product = 'Free CRM' THEN 1 ELSE 0 END), 1) AS free_crm_share_pct
FROM stacked
WHERE value IS NOT NULL            -- the 25 signups with no visit have no page/device
GROUP BY dimension, value, signup_month, period
ORDER BY dimension, value, month;


-- ---------------------------------------------------------------------
-- STEP 5. finance_view — customers by the month the deal CLOSED
-- (how finance counts). Includes the 15 deals with a broken lead id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE finance_view AS
SELECT
    CAST(DATE_TRUNC('month', close_dt) AS DATE)            AS close_month,
    SUM(CASE WHEN is_zero_amount = 0 THEN 1 ELSE 0 END)    AS paying_customers,
    COUNT(*)                                               AS all_closed_opps,
    SUM(amount)                                            AS deal_value
FROM opportunities_clean
GROUP BY 1
ORDER BY 1;
