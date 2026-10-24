-- =====================================================================
-- 01_clean.sql — Northwind CRM: raw CSVs -> cleaned tables
-- Engine: DuckDB (standard SQL; reads CSVs directly).
-- Every rule is numbered (R1..R13) and matches the data-validation doc.
-- =====================================================================

-- ---------------------------------------------------------------------
-- SESSIONS  (1 row = 1 website visit)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE sessions_clean AS
WITH raw AS (
    SELECT * FROM read_csv_auto('data/sessions.csv')
),
url AS (
    SELECT
        *,
        -- R2: normalize URL: lowercase, drop query string, drop geo prefix, drop trailing slash
        COALESCE(NULLIF(
            regexp_replace(
                regexp_replace(lower(split_part(entry_url, '?', 1)), '^/(uk|in|de|au|ca)(/|$)', '/'),
            '/+$', ''),
        ''), '/') AS url_norm
    FROM raw
)
SELECT
    session_id,
    visitor_id,
    CAST(event_dt AS DATE)                  AS event_dt,
    -- R1: channel labels have casing / trailing-space variants ("Display ", "direct")
    CASE lower(trim(mktg_channel))
        WHEN 'direct'         THEN 'Direct'
        WHEN 'display'        THEN 'Display'
        WHEN 'email'          THEN 'Email'
        WHEN 'organic search' THEN 'Organic Search'
        WHEN 'paid search'    THEN 'Paid Search'
        WHEN 'referral'       THEN 'Referral'
        WHEN 'social'         THEN 'Social'
    END                                      AS mktg_channel,
    geo,
    device_type,
    entry_url,
    -- R2: 135 raw URLs -> 7 page types
    CASE
        WHEN url_norm LIKE '/blog%' OR url_norm LIKE '/resources%'    THEN 'content'
        WHEN url_norm IN ('/', '/home', '/index')                     THEN 'home'
        WHEN url_norm LIKE '/pricing%' OR url_norm LIKE '/plans%'     THEN 'pricing'
        WHEN url_norm IN ('/offers/free-crm', '/lp/free-crm')         THEN 'free_crm_lp'
        WHEN url_norm = '/get/starter-trial'                          THEN 'trial_lp'
        WHEN url_norm IN ('/go/crm', '/campaign/spring-2026')         THEN 'campaign_lp'
        WHEN url_norm LIKE '/product%' OR url_norm LIKE '/features%'  THEN 'product'
        ELSE 'other'
    END                                      AS page_type,
    converted_flag,
    -- R3: 300 sessions without visitor_id: kept, flagged
    visitor_id IS NULL                       AS visitor_missing
FROM url;

-- ---------------------------------------------------------------------
-- SIGNUPS  (1 row = 1 lead = 1 product signup)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE signups_clean AS
WITH dedup AS (
    -- R4: drop exact duplicate rows
    SELECT DISTINCT * FROM read_csv_auto('data/signups.csv')
),
sized AS (
    SELECT
        * REPLACE (
            -- R5: company_size sentinels (-5, 999999) -> NULL
            CASE WHEN company_size < 1 OR company_size >= 999999 THEN NULL
                 ELSE company_size END AS company_size
        )
    FROM dedup
),
ranked AS (
    -- R6: same lead_id twice with conflicting attributes -> keep the most complete row
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY lead_id
            ORDER BY (geo IS NOT NULL)::INT + (company_size IS NOT NULL)::INT DESC
        ) AS rn
    FROM sized
)
SELECT
    r.lead_id,
    r.visitor_id,
    r.session_id,
    -- R7: 8 signups dated July (outside window); 99.9% of signups happen the same
    --     day as their session -> replace with the session date
    CASE WHEN CAST(r.created_dt AS DATE) > DATE '2026-06-30' AND s.event_dt IS NOT NULL
         THEN s.event_dt ELSE CAST(r.created_dt AS DATE) END          AS created_dt,
    CAST(r.created_dt AS DATE) > DATE '2026-06-30'
         AND s.event_dt IS NOT NULL                                     AS created_dt_imputed,
    r.mktg_channel,
    r.product_code,
    CASE r.product_code WHEN 'STR' THEN 'Starter'
                        WHEN 'PRO' THEN 'Pro'
                        WHEN 'FCRM' THEN 'Free CRM' END                 AS product,
    r.geo,
    r.company_size,
    -- R8: session_id not found in sessions (malformed key S9xxxxxxx): kept, flagged
    s.session_id IS NULL                                                AS session_orphan
FROM ranked r
LEFT JOIN sessions_clean s USING (session_id)
WHERE r.rn = 1;

-- ---------------------------------------------------------------------
-- OPPORTUNITIES  (1 row = 1 closed deal)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE opportunities_clean AS
WITH dedup AS (
    -- R9: drop exact duplicate rows
    SELECT DISTINCT * FROM read_csv_auto('data/opportunities.csv')
)
SELECT
    o.opp_id,
    o.lead_id,
    CAST(o.close_dt AS DATE)                                            AS close_dt,
    o.plan,
    -- R10: amounts 1000x list price (35000 / 110000) -> unit error, divide by 1000
    CASE WHEN o.amount IN (35000, 110000) THEN o.amount // 1000
         ELSE o.amount END                                              AS amount,
    -- R11: $0 deals: closed but not paying -> excluded from "paying customers"
    o.amount = 0                                                        AS zero_amount,
    -- R12: negative days_to_close is a sign bug -> recompute from dates
    COALESCE(date_diff('day', g.created_dt, CAST(o.close_dt AS DATE)),
             abs(o.days_to_close))                                      AS days_to_close,
    -- R13: lead_id not found in signups (malformed key G9xxxxxx): kept, flagged
    g.lead_id IS NULL                                                   AS lead_orphan
FROM dedup o
LEFT JOIN signups_clean g USING (lead_id);

-- ---------------------------------------------------------------------
-- ANALYSIS BASE: 1 row per signup with origin attributes + 30-day win
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE signup_outcomes AS
WITH first_visit AS (
    SELECT visitor_id, MIN(event_dt) AS first_visit_dt
    FROM sessions_clean
    WHERE visitor_id IS NOT NULL
    GROUP BY visitor_id
)
SELECT
    g.*,
    date_trunc('month', g.created_dt)::DATE                             AS signup_month,
    CASE WHEN g.created_dt < DATE '2026-04-01' THEN 'Q1' ELSE 'Q2' END  AS period,
    s.device_type,
    s.page_type,
    CASE WHEN fv.first_visit_dt < g.created_dt THEN 'Returning' ELSE 'New' END AS visitor_type,
    CASE WHEN g.company_size IS NULL THEN 'Unknown'
         WHEN g.company_size <= 10  THEN '1-10'
         WHEN g.company_size <= 50  THEN '11-50'
         WHEN g.company_size <= 200 THEN '51-200'
         ELSE '201+' END                                                AS company_size_bucket,
    o.plan                                                              AS won_plan,
    o.amount                                                            AS won_amount,
    o.days_to_close,
    -- Win definition: paying (amount > 0) opp closed within 30 days of signup
    (o.opp_id IS NOT NULL AND o.days_to_close <= 30)                    AS win_30d
FROM signups_clean g
LEFT JOIN sessions_clean s       USING (session_id)
LEFT JOIN first_visit fv         ON fv.visitor_id = g.visitor_id
LEFT JOIN opportunities_clean o  ON o.lead_id = g.lead_id AND NOT o.zero_amount;
