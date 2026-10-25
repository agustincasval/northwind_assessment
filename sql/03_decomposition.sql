-- =====================================================================
-- 03_decomposition.sql — How much of the drop in paying customers
-- comes from MORE SIGNUPS, a different SKU MIX, or CONVERSION changes
-- Snowflake SQL (also runs in DuckDB). Run after 01_clean.sql.
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
--
-- THE IDEA (Kitagawa decomposition)
--   Wins per month = Signups per month  x  Blended conversion
--   Blended conversion = sum over SKUs of (SKU share of signups x SKU conversion)
--
--   Between Q1 and Q2 three things changed: signups, SKU mix and SKU conversion.
--   We split the change in wins into three pieces, using the average of both
--   periods for everything that is held still. The pieces add up exactly:
--     VOLUME = change in signups              x  average blended conversion
--     MIX    = average signups x change in SKU share   x average SKU conversion
--     RATE   = average signups x average SKU share      x change in SKU conversion
--
-- ASSUMPTION: Free CRM didn't exist in Q1, so it has no Q1 conversion.
-- We use its Q2 conversion for both periods, which puts its whole effect in MIX.
-- =====================================================================


CREATE OR REPLACE TABLE kitagawa AS
WITH sku_by_period AS (
    -- Average signups and wins per month, for each period and SKU
    SELECT period,
           product,
           COUNT(*) / 3.0    AS signups_mo,     -- 3 months per period
           SUM(is_win) / 3.0 AS wins_mo
    FROM signup_outcomes
    GROUP BY period, product
),
all_combinations AS (
    -- Every SKU in both periods, so Free CRM gets a Q1 row (with zeros)
    SELECT p.period, k.product
    FROM (VALUES ('Q1'), ('Q2')) AS p(period)
    CROSS JOIN (SELECT DISTINCT product FROM signup_outcomes) AS k
),
filled AS (
    SELECT a.period,
           a.product,
           COALESCE(b.signups_mo, 0) AS signups_mo,
           COALESCE(b.wins_mo, 0)    AS wins_mo
    FROM all_combinations a
    LEFT JOIN sku_by_period b
           ON b.period = a.period AND b.product = a.product
),
shares_and_rates AS (
    SELECT period,
           product,
           signups_mo / SUM(signups_mo) OVER (PARTITION BY period) AS mix,    -- SKU share of signups
           wins_mo / NULLIF(signups_mo, 0)                         AS rate    -- SKU conversion (NULL if no signups)
    FROM filled
),
side_by_side AS (
    -- Q1 and Q2 next to each other, one row per SKU
    SELECT q1.product,
           q1.mix                       AS mix_q1,
           q2.mix                       AS mix_q2,
           COALESCE(q1.rate, q2.rate)   AS rate_q1,     -- the Free CRM assumption
           q2.rate                      AS rate_q2
    FROM shares_and_rates q1
    JOIN shares_and_rates q2
      ON q2.product = q1.product
    WHERE q1.period = 'Q1' AND q2.period = 'Q2'
),
period_totals AS (
    SELECT period,
           SUM(signups_mo)                  AS n,       -- signups per month
           SUM(wins_mo)                     AS w,       -- wins per month
           SUM(wins_mo) / SUM(signups_mo)   AS r        -- blended conversion
    FROM filled
    GROUP BY period
),
t AS (
    SELECT q1.n AS n1, q2.n AS n2, q1.w AS w1, q2.w AS w2, q1.r AS r1, q2.r AS r2
    FROM period_totals q1
    JOIN period_totals q2 ON q1.period = 'Q1' AND q2.period = 'Q2'
)
SELECT 'Q1 wins / month' AS step, NULL AS product, w1 AS wins FROM t
UNION ALL
SELECT 'Volume effect', NULL, (n2 - n1) * (r1 + r2) / 2 FROM t
UNION ALL
SELECT 'Mix effect', s.product,
       (t.n1 + t.n2) / 2 * (s.mix_q2 - s.mix_q1) * (s.rate_q1 + s.rate_q2) / 2
FROM side_by_side s CROSS JOIN t
UNION ALL
SELECT 'Rate effect', s.product,
       (t.n1 + t.n2) / 2 * (s.mix_q1 + s.mix_q2) / 2 * (s.rate_q2 - s.rate_q1)
FROM side_by_side s CROSS JOIN t
UNION ALL
SELECT 'Q2 wins / month', NULL, w2 FROM t;


-- The waterfall: one bar per effect. Volume + Mix + Rate = Q2 - Q1, exactly.
SELECT step, ROUND(SUM(wins), 1) AS wins_per_month
FROM kitagawa
GROUP BY step
ORDER BY CASE step WHEN 'Q1 wins / month' THEN 1
                   WHEN 'Volume effect'   THEN 2
                   WHEN 'Mix effect'      THEN 3
                   WHEN 'Rate effect'     THEN 4
                   ELSE 5 END;
