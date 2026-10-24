-- =====================================================================
-- 03_decomposition.sql — Kitagawa decomposition of the change in
-- paying customers (30-day wins) per month, Q1 vs Q2 2026.
--
--   Wins = N x R            N = signups / month,  R = blended conversion
--   R    = SUM_i m_i x r_i  m_i = product mix share, r_i = product conversion
--
-- Exact symmetric (Kitagawa) split, using period averages (bar):
--   dWins  = dN x R_bar                        -> VOLUME effect
--          + N_bar x SUM_i dm_i x r_bar_i      -> MIX effect   (by product)
--          + N_bar x SUM_i m_bar_i x dr_i      -> RATE effect  (by product)
--
-- Assumption: Free CRM did not exist in Q1, so it has no Q1 rate.
-- We set r_Q1(Free) = r_Q2(Free): Free contributes no rate effect and its
-- whole impact is counted as mix. Requires 01_clean.sql.
-- =====================================================================

CREATE OR REPLACE TABLE kitagawa AS
WITH by_product AS (
    SELECT period, product,
           COUNT(*) / 3.0                AS signups_mo,
           SUM(win_30d::INT) / 3.0       AS wins_mo
    FROM signup_outcomes
    GROUP BY ALL
),
grid AS (   -- every product in both periods (Free CRM has zero Q1 signups)
    SELECT p.period, pr.product
    FROM (VALUES ('Q1'), ('Q2')) p(period)
    CROSS JOIN (SELECT DISTINCT product FROM signup_outcomes) pr
),
filled AS (
    SELECT g.period, g.product,
           COALESCE(b.signups_mo, 0) AS signups_mo,
           COALESCE(b.wins_mo, 0)    AS wins_mo
    FROM grid g LEFT JOIN by_product b USING (period, product)
),
shares AS (
    SELECT *,
           signups_mo / SUM(signups_mo) OVER (PARTITION BY period) AS mix,
           wins_mo / NULLIF(signups_mo, 0)                         AS rate
    FROM filled
),
wide AS (
    SELECT q1.product,
           q1.mix AS mix_q1, q2.mix AS mix_q2,
           COALESCE(q1.rate, q2.rate) AS rate_q1,   -- Free CRM assumption
           q2.rate AS rate_q2
    FROM shares q1 JOIN shares q2 USING (product)
    WHERE q1.period = 'Q1' AND q2.period = 'Q2'
),
totals AS (
    SELECT period, SUM(signups_mo) AS n, SUM(wins_mo) AS w, SUM(wins_mo) / SUM(signups_mo) AS r
    FROM filled GROUP BY period
),
t AS (
    SELECT q1.n AS n1, q2.n AS n2, q1.w AS w1, q2.w AS w2, q1.r AS r1, q2.r AS r2
    FROM totals q1, totals q2 WHERE q1.period = 'Q1' AND q2.period = 'Q2'
)
SELECT 'Q1 wins / month' AS step, NULL AS product, w1 AS wins FROM t
UNION ALL
SELECT 'Volume effect', NULL, (n2 - n1) * (r1 + r2) / 2 FROM t
UNION ALL
SELECT 'Mix effect', w.product,
       (t.n1 + t.n2) / 2 * (w.mix_q2 - w.mix_q1) * (w.rate_q1 + w.rate_q2) / 2
FROM wide w, t
UNION ALL
SELECT 'Rate effect', w.product,
       (t.n1 + t.n2) / 2 * (w.mix_q1 + w.mix_q2) / 2 * (w.rate_q2 - w.rate_q1)
FROM wide w, t
UNION ALL
SELECT 'Q2 wins / month', NULL, w2 FROM t;

-- Waterfall view (one bar per effect)
SELECT step, ROUND(SUM(wins), 1) AS wins_per_month
FROM kitagawa
GROUP BY step
ORDER BY CASE step WHEN 'Q1 wins / month' THEN 1 WHEN 'Volume effect' THEN 2
                   WHEN 'Mix effect' THEN 3 WHEN 'Rate effect' THEN 4 ELSE 5 END;
