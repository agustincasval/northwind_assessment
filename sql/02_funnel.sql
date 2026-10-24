-- =====================================================================
-- 02_funnel.sql — Funnel metrics on cleaned data. Requires 01_clean.sql.
-- Win = paying opp (amount > 0) closed within 30 days of signup.
-- =====================================================================

-- 1. Monthly cohort funnel: sessions -> signups -> 30-day wins -> new MRR
CREATE OR REPLACE TABLE monthly_funnel AS
WITH sess AS (
    SELECT date_trunc('month', event_dt)::DATE AS month, COUNT(*) AS sessions
    FROM sessions_clean GROUP BY 1
),
sig AS (
    SELECT signup_month AS month,
           COUNT(*)                                             AS signups,
           SUM(win_30d::INT)                                    AS wins_30d,
           SUM(CASE WHEN win_30d THEN won_amount ELSE 0 END)    AS new_mrr_30d
    FROM signup_outcomes GROUP BY 1
)
SELECT month, sessions, signups, wins_30d, new_mrr_30d,
       ROUND(100.0 * signups  / sessions, 2) AS sess_to_signup_pct,
       ROUND(100.0 * wins_30d / signups, 1)  AS signup_to_win_pct,
       ROUND(100.0 * wins_30d / sessions, 2) AS sess_to_win_pct
FROM sess JOIN sig USING (month)
ORDER BY month;

-- 1b. Weekly cohort funnel (Monday-start weeks). Only complete 7-day weeks are
--     kept: the first (Jan 1-4) and last (Jun 29-30) weeks are partial.
CREATE OR REPLACE TABLE weekly_funnel AS
SELECT date_trunc('week', created_dt)::DATE         AS week_start,
       COUNT(*)                                     AS signups,
       SUM((product = 'Free CRM')::INT)             AS free_crm_signups,
       SUM(win_30d::INT)                            AS wins_30d,
       ROUND(100.0 * AVG(win_30d::INT), 1)          AS signup_to_win_pct
FROM signup_outcomes
GROUP BY 1
HAVING date_diff('day', MIN(created_dt), MAX(created_dt)) = 6   -- full week only
ORDER BY 1;

-- 2. Same funnel split by product (mix, conversion, wins, MRR)
CREATE OR REPLACE TABLE product_funnel AS
SELECT signup_month AS month, product,
       COUNT(*)                                                      AS signups,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY signup_month), 1) AS mix_pct,
       SUM(win_30d::INT)                                             AS wins_30d,
       ROUND(100.0 * AVG(win_30d::INT), 1)                           AS signup_to_win_pct,
       SUM(CASE WHEN win_30d THEN won_amount ELSE 0 END)             AS new_mrr_30d
FROM signup_outcomes
GROUP BY signup_month, product
ORDER BY month, product;

-- 3. Signup -> win conversion by origin slice, monthly + Q1 vs Q2
--    (long format: one row per dimension x value x month)
CREATE OR REPLACE TABLE slice_conversion AS
WITH long AS (
    SELECT signup_month, period, win_30d, product, 'channel'      AS dimension, mktg_channel        AS value FROM signup_outcomes
    UNION ALL SELECT signup_month, period, win_30d, product, 'entry_page',   page_type           FROM signup_outcomes
    UNION ALL SELECT signup_month, period, win_30d, product, 'device',       device_type         FROM signup_outcomes
    UNION ALL SELECT signup_month, period, win_30d, product, 'visitor_type', visitor_type        FROM signup_outcomes
    UNION ALL SELECT signup_month, period, win_30d, product, 'company_size', company_size_bucket FROM signup_outcomes
    UNION ALL SELECT signup_month, period, win_30d, product, 'geo',          COALESCE(geo, 'Unknown') FROM signup_outcomes
)
SELECT dimension, value,
       strftime(signup_month, '%Y-%m')                   AS month,
       period,
       COUNT(*)                                          AS signups,
       SUM(win_30d::INT)                                 AS wins_30d,
       ROUND(100.0 * AVG(win_30d::INT), 1)               AS signup_to_win_pct,
       ROUND(100.0 * AVG((product = 'Free CRM')::INT), 1) AS free_crm_share_pct
FROM long
WHERE value IS NOT NULL            -- drops 25 signups with no matching session
GROUP BY dimension, value, signup_month, period
ORDER BY dimension, value, month;

-- 4. Finance view: paying customers by CLOSE month (incl. orphan opps)
CREATE OR REPLACE TABLE finance_view AS
SELECT date_trunc('month', close_dt)::DATE AS close_month,
       COUNT(*) FILTER (WHERE NOT zero_amount)         AS paying_customers,
       COUNT(*)                                         AS all_closed_opps,
       SUM(amount)                                      AS new_mrr
FROM opportunities_clean
GROUP BY 1 ORDER BY 1;

SELECT * FROM monthly_funnel;
