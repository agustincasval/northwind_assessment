-- =====================================================================
-- 01_clean.sql — Clean the three raw tables and join them
-- Snowflake SQL (also runs in DuckDB). Rule ids R1–R14 match the
-- Data methodology doc. Flags are 1/0 so they can be summed and averaged.
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
-- STEP 1. sessions_clean — one row per website visit
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE sessions_clean AS
WITH with_clean_url AS (
    SELECT
        s.*,
        -- R2. Make the URL comparable. Read it inside-out:
        --   1) cut everything after "?"         /pricing?plan=starter -> /pricing
        --   2) lowercase                        /HOME -> /home
        --   3) drop the country prefix          /uk/blog/x -> /blog/x
        --   4) drop the trailing slash          /pricing/ -> /pricing
        --   5) if nothing is left, it was "/"   (the home page)
        COALESCE(
            NULLIF(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(LOWER(SPLIT_PART(s.entry_url, '?', 1)),
                                   '^/(uk|in|de|au|ca)(/|$)', '/'),
                    '/+$', ''),
                ''),
            '/') AS url_clean
    FROM sessions s
)
SELECT
    session_id,
    visitor_id,
    CAST(event_dt AS DATE) AS event_dt,

    -- R1. Same channel written different ways ("Display ", "direct") -> one name
    CASE LOWER(TRIM(mktg_channel))
        WHEN 'direct'         THEN 'Direct'
        WHEN 'display'        THEN 'Display'
        WHEN 'email'          THEN 'Email'
        WHEN 'organic search' THEN 'Organic Search'
        WHEN 'paid search'    THEN 'Paid Search'
        WHEN 'referral'       THEN 'Referral'
        WHEN 'social'         THEN 'Social'
    END AS mktg_channel,

    geo,
    device_type,
    entry_url,

    -- R2. Group the clean URL into 7 page types
    CASE
        WHEN url_clean LIKE '/blog%'    OR url_clean LIKE '/resources%' THEN 'content'
        WHEN url_clean IN ('/', '/home', '/index')                      THEN 'home'
        WHEN url_clean LIKE '/pricing%' OR url_clean LIKE '/plans%'     THEN 'pricing'
        WHEN url_clean IN ('/offers/free-crm', '/lp/free-crm')          THEN 'free_crm_lp'
        WHEN url_clean = '/get/starter-trial'                           THEN 'trial_lp'
        WHEN url_clean IN ('/go/crm', '/campaign/spring-2026')          THEN 'campaign_lp'
        WHEN url_clean LIKE '/product%' OR url_clean LIKE '/features%'  THEN 'product'
        ELSE 'other'
    END AS page_type,

    converted_flag,

    -- R3. 300 visits have no visitor id. Keep them, just mark them.
    CASE WHEN visitor_id IS NULL THEN 1 ELSE 0 END AS is_visitor_missing
FROM with_clean_url;


-- ---------------------------------------------------------------------
-- STEP 2. signups_clean — one row per lead
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE signups_clean AS
WITH no_duplicates AS (
    -- R4. Remove rows that are exact copies of another row
    SELECT DISTINCT * FROM signups
),
fixed_values AS (
    SELECT
        lead_id,
        visitor_id,
        session_id,
        CAST(created_dt AS DATE) AS created_dt,
        mktg_channel,
        product_code,
        -- R14. The text 'N/A' is not a country -> treat it as unknown
        NULLIF(TRIM(geo), 'N/A') AS geo,
        -- R5. -5 or 999,999 employees are not real -> treat as unknown
        CASE WHEN company_size < 1 OR company_size >= 999999 THEN NULL
             ELSE company_size END AS company_size
    FROM no_duplicates
),
ranked AS (
    -- R6. A few leads appear twice with different details.
    -- Score each row by how complete it is (0, 1 or 2 known fields)
    -- and number the rows of each lead from most to least complete.
    SELECT
        f.*,
        ROW_NUMBER() OVER (
            PARTITION BY lead_id
            ORDER BY (CASE WHEN geo IS NOT NULL THEN 1 ELSE 0 END)
                   + (CASE WHEN company_size IS NOT NULL THEN 1 ELSE 0 END) DESC
        ) AS row_rank
    FROM fixed_values f
)
SELECT
    r.lead_id,
    r.visitor_id,
    r.session_id,

    -- R7. 8 signups are dated in July, after the data ends. Every signup
    -- happens on the same day as its visit, so use the visit date instead.
    CASE WHEN r.created_dt > DATE '2026-06-30' AND s.event_dt IS NOT NULL
         THEN s.event_dt
         ELSE r.created_dt END AS created_dt,
    CASE WHEN r.created_dt > DATE '2026-06-30' AND s.event_dt IS NOT NULL
         THEN 1 ELSE 0 END AS is_date_fixed,

    r.mktg_channel,
    r.product_code,
    CASE r.product_code
        WHEN 'STR'  THEN 'Starter'
        WHEN 'PRO'  THEN 'Pro'
        WHEN 'FCRM' THEN 'Free CRM'
    END AS product,
    r.geo,
    r.company_size,

    -- R8. 25 signups point to a visit that doesn't exist (broken id).
    -- Keep them, just mark them.
    CASE WHEN s.session_id IS NULL THEN 1 ELSE 0 END AS is_session_orphan
FROM ranked r
LEFT JOIN sessions_clean s
       ON s.session_id = r.session_id
WHERE r.row_rank = 1;          -- keep only the most complete row per lead


-- ---------------------------------------------------------------------
-- STEP 3. opportunities_clean — one row per closed deal
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE opportunities_clean AS
WITH no_duplicates AS (
    -- R9. Remove rows that are exact copies of another row
    SELECT DISTINCT * FROM opportunities
)
SELECT
    o.opp_id,
    o.lead_id,
    CAST(o.close_dt AS DATE) AS close_dt,
    o.plan,

    -- R10. 35,000 and 110,000 are the list prices x1000 (unit error)
    CASE WHEN o.amount IN (35000, 110000) THEN o.amount / 1000
         ELSE o.amount END AS amount,

    -- R11. $0 deals closed but nobody pays -> not a paying customer
    CASE WHEN o.amount = 0 THEN 1 ELSE 0 END AS is_zero_amount,

    -- R12. Some days_to_close are negative (sign bug).
    -- Recompute from the dates; if the lead is missing, flip the sign.
    COALESCE(CAST(o.close_dt AS DATE) - g.created_dt,
             ABS(o.days_to_close)) AS days_to_close,

    -- R13. 15 deals point to a lead that doesn't exist (broken id).
    -- Keep them, just mark them.
    CASE WHEN g.lead_id IS NULL THEN 1 ELSE 0 END AS is_lead_orphan
FROM no_duplicates o
LEFT JOIN signups_clean g
       ON g.lead_id = o.lead_id;


-- ---------------------------------------------------------------------
-- STEP 4. signup_outcomes — one row per signup, everything we need
-- to analyze it: where it came from, which SKU, and did it pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE signup_outcomes AS
WITH first_visit AS (
    -- The first day each visitor came to the site
    SELECT visitor_id, MIN(event_dt) AS first_visit_dt
    FROM sessions_clean
    WHERE visitor_id IS NOT NULL
    GROUP BY visitor_id
),
paid_deals AS (
    -- Only deals where someone actually pays
    SELECT * FROM opportunities_clean WHERE is_zero_amount = 0
)
SELECT
    g.*,

    -- Cohort = the month the lead signed up
    CAST(DATE_TRUNC('month', g.created_dt) AS DATE) AS signup_month,
    CASE WHEN g.created_dt < DATE '2026-04-01' THEN 'Q1' ELSE 'Q2' END AS period,

    -- Where the signup came from (its visit)
    s.device_type,
    s.page_type,
    CASE WHEN fv.first_visit_dt < g.created_dt THEN 'Returning' ELSE 'New' END AS visitor_type,
    CASE
        WHEN g.company_size IS NULL THEN 'Unknown'
        WHEN g.company_size <= 10   THEN '1-10'
        WHEN g.company_size <= 50   THEN '11-50'
        WHEN g.company_size <= 200  THEN '51-200'
        ELSE '201+'
    END AS company_size_bucket,

    -- The deal it turned into, if any
    o.plan   AS won_plan,
    o.amount AS won_amount,
    o.days_to_close,

    -- THE WIN DEFINITION: a paying deal closed within 30 days of signup.
    -- 1 = paying customer, 0 = not. Summing this column counts wins.
    CASE WHEN o.opp_id IS NOT NULL AND o.days_to_close <= 30 THEN 1 ELSE 0 END AS is_win
FROM signups_clean g
LEFT JOIN sessions_clean s ON s.session_id = g.session_id
LEFT JOIN first_visit fv   ON fv.visitor_id = g.visitor_id
LEFT JOIN paid_deals o     ON o.lead_id = g.lead_id;
