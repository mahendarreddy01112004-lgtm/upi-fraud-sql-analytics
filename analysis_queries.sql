-- ============================================================
-- Project : UPI Transactions & Fraud Pattern Analytics
-- File    : analysis_queries.sql
-- Author  : Mahendar Reddy Maram
-- Engine  : SQLite 3.35+ (window functions supported)
--
-- This file is organised into two parts:
--   PART A - Business / Reporting Analytics
--   PART B - Fraud Detection Analytics (the highlight of this project)
--
-- Each query is commented with the business question it answers
-- and the SQL technique it demonstrates.
-- ============================================================


-- ============================================================
-- PART A: BUSINESS & REPORTING ANALYTICS
-- ============================================================

-- A1. Monthly transaction volume & value trend
-- Technique: DATE functions, GROUP BY, aggregation
SELECT
    strftime('%Y-%m', txn_timestamp) AS month,
    COUNT(*)                          AS total_transactions,
    ROUND(SUM(amount), 2)             AS total_value,
    ROUND(AVG(amount), 2)             AS avg_txn_value
FROM transactions
WHERE status = 'SUCCESS'
GROUP BY month
ORDER BY month;


-- A2. Top 10 merchants by revenue, ranked
-- Technique: Window function RANK()
SELECT *
FROM (
    SELECT
        m.merchant_name,
        m.category,
        ROUND(SUM(t.amount), 2) AS revenue,
        RANK() OVER (ORDER BY SUM(t.amount) DESC) AS revenue_rank
    FROM transactions t
    JOIN merchants m ON m.merchant_id = t.merchant_id
    WHERE t.status = 'SUCCESS'
    GROUP BY m.merchant_id
) ranked
WHERE revenue_rank <= 10;


-- A3. City-wise transaction volume with a running (cumulative) total
-- Technique: Window function SUM() OVER with ORDER BY
SELECT
    city,
    txn_count,
    SUM(txn_count) OVER (ORDER BY txn_count DESC) AS running_total
FROM (
    SELECT city, COUNT(*) AS txn_count
    FROM transactions
    GROUP BY city
) t
ORDER BY txn_count DESC;


-- A4. Failed-transaction rate by bank (reliability report)
-- Technique: Conditional aggregation, CASE WHEN
SELECT
    b.bank_name,
    COUNT(*) AS total_txns,
    SUM(CASE WHEN t.status = 'FAILED' THEN 1 ELSE 0 END) AS failed_txns,
    ROUND(100.0 * SUM(CASE WHEN t.status = 'FAILED' THEN 1 ELSE 0 END) / COUNT(*), 2) AS failure_rate_pct
FROM transactions t
JOIN banks b ON b.bank_id = t.bank_id
GROUP BY b.bank_name
ORDER BY failure_rate_pct DESC;


-- A5. Latest transaction per user (common "most recent record" pattern)
-- Technique: Window function ROW_NUMBER() + CTE
WITH ranked_txns AS (
    SELECT
        t.*,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY txn_timestamp DESC) AS rn
    FROM transactions t
)
SELECT user_id, transaction_id, amount, txn_timestamp
FROM ranked_txns
WHERE rn = 1
LIMIT 20;


-- A6. RFM-style customer segmentation (Recency, Frequency, Monetary)
-- Technique: Multiple CTEs, date arithmetic, NTILE()
WITH customer_stats AS (
    SELECT
        user_id,
        julianday('2026-07-01') - julianday(MAX(txn_timestamp)) AS recency_days,
        COUNT(*) AS frequency,
        ROUND(SUM(amount), 2) AS monetary
    FROM transactions
    WHERE status = 'SUCCESS'
    GROUP BY user_id
),
scored AS (
    SELECT
        user_id, recency_days, frequency, monetary,
        NTILE(4) OVER (ORDER BY recency_days ASC)  AS recency_score,
        NTILE(4) OVER (ORDER BY frequency DESC)    AS frequency_score,
        NTILE(4) OVER (ORDER BY monetary DESC)     AS monetary_score
    FROM customer_stats
)
SELECT *,
    CASE
        WHEN recency_score = 1 AND frequency_score = 1 AND monetary_score = 1 THEN 'Champion'
        WHEN recency_score <= 2 AND frequency_score <= 2 THEN 'Loyal'
        WHEN recency_score >= 3 THEN 'At Risk'
        ELSE 'Regular'
    END AS customer_segment
FROM scored
ORDER BY monetary ASC
LIMIT 20;


-- A7. De-duplication check: find duplicate transaction "fingerprints"
-- (same user, same amount, same merchant, within 60 seconds)
-- Technique: Self-join with window LAG()
WITH ordered AS (
    SELECT
        transaction_id, user_id, merchant_id, amount, txn_timestamp,
        LAG(txn_timestamp) OVER (PARTITION BY user_id, merchant_id, amount ORDER BY txn_timestamp) AS prev_ts
    FROM transactions
)
SELECT *,
    (julianday(txn_timestamp) - julianday(prev_ts)) * 86400 AS seconds_since_prev
FROM ordered
WHERE prev_ts IS NOT NULL
  AND (julianday(txn_timestamp) - julianday(prev_ts)) * 86400 <= 60;


-- ============================================================
-- PART B: FRAUD DETECTION ANALYTICS  (project highlight)
-- ============================================================

-- B1. VELOCITY FRAUD: Users with 5+ transactions within any 2-minute window
-- Technique: Window function COUNT() OVER with a RANGE-style approach via
--            self-join on timestamp difference (since SQLite RANGE BETWEEN
--            with time intervals is limited, this uses LAG-based chaining).
WITH txn_with_prev AS (
    SELECT
        transaction_id, user_id, txn_timestamp,
        LAG(txn_timestamp, 4) OVER (PARTITION BY user_id ORDER BY txn_timestamp) AS ts_4_back
    FROM transactions
    WHERE status = 'SUCCESS'
)
SELECT
    user_id,
    COUNT(*) AS burst_events
FROM txn_with_prev
WHERE ts_4_back IS NOT NULL
  AND (julianday(txn_timestamp) - julianday(ts_4_back)) * 86400 <= 120   -- 5 txns within 120 seconds
GROUP BY user_id
ORDER BY burst_events DESC;


-- B2. ODD-HOUR HIGH-VALUE TRANSACTIONS (1 AM - 4 AM, amount > user's typical spend)
-- Technique: CTE for per-user average, JOIN + HAVING filter
WITH user_avg AS (
    SELECT user_id, AVG(amount) AS avg_amount
    FROM transactions
    WHERE status = 'SUCCESS'
    GROUP BY user_id
)
SELECT
    t.transaction_id, t.user_id, t.amount, t.txn_timestamp,
    ROUND(ua.avg_amount, 2) AS user_avg_amount,
    ROUND(t.amount / ua.avg_amount, 1) AS times_above_average
FROM transactions t
JOIN user_avg ua ON ua.user_id = t.user_id
WHERE CAST(strftime('%H', t.txn_timestamp) AS INTEGER) BETWEEN 1 AND 4
  AND t.amount > ua.avg_amount * 5
ORDER BY times_above_average DESC;


-- B3. FAILED-RETRY BURST: same user + same merchant + same amount,
--     3+ failed attempts followed by a success within a short window
-- Technique: CTE, conditional aggregation, HAVING
WITH attempt_groups AS (
    SELECT
        user_id, merchant_id, amount,
        COUNT(*) AS attempt_count,
        SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) AS failed_count,
        SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS success_count,
        MIN(txn_timestamp) AS first_attempt,
        MAX(txn_timestamp) AS last_attempt
    FROM transactions
    GROUP BY user_id, merchant_id, amount
)
SELECT *
FROM attempt_groups
WHERE failed_count >= 3 AND success_count >= 1
ORDER BY failed_count DESC;


-- B4. GEO-MISMATCH / IMPOSSIBLE TRAVEL: same user transacting in two
--     different cities within a short time window on the same day
-- Technique: Self-join on the same table
SELECT
    t1.user_id,
    t1.city AS city_1, t1.txn_timestamp AS time_1,
    t2.city AS city_2, t2.txn_timestamp AS time_2,
    ROUND((julianday(t2.txn_timestamp) - julianday(t1.txn_timestamp)) * 24, 2) AS hours_apart
FROM transactions t1
JOIN transactions t2
    ON t1.user_id = t2.user_id
    AND t1.transaction_id < t2.transaction_id
    AND date(t1.txn_timestamp) = date(t2.txn_timestamp)
    AND t1.city != t2.city
WHERE (julianday(t2.txn_timestamp) - julianday(t1.txn_timestamp)) * 24 <= 3
ORDER BY t1.user_id;


-- B5. COMPOSITE FRAUD SCORE: combine multiple weak signals into one score
-- Technique: Multiple CTEs unioned + aggregated scoring (mirrors how real
--            fraud engines combine rule outputs into a single risk score)
WITH velocity_flags AS (
    SELECT DISTINCT user_id, 3 AS risk_points, 'VELOCITY' AS reason
    FROM (
        SELECT user_id, txn_timestamp,
               LAG(txn_timestamp, 4) OVER (PARTITION BY user_id ORDER BY txn_timestamp) AS ts_4_back
        FROM transactions WHERE status = 'SUCCESS'
    )
    WHERE ts_4_back IS NOT NULL
      AND (julianday(txn_timestamp) - julianday(ts_4_back)) * 86400 <= 120
),
oddhour_flags AS (
    SELECT DISTINCT t.user_id, 2 AS risk_points, 'ODD_HOUR_HIGH_VALUE' AS reason
    FROM transactions t
    JOIN (SELECT user_id, AVG(amount) AS avg_amount FROM transactions GROUP BY user_id) ua
        ON ua.user_id = t.user_id
    WHERE CAST(strftime('%H', t.txn_timestamp) AS INTEGER) BETWEEN 1 AND 4
      AND t.amount > ua.avg_amount * 5
),
retry_flags AS (
    SELECT DISTINCT user_id, 2 AS risk_points, 'FAILED_RETRY_BURST' AS reason
    FROM (
        SELECT user_id, merchant_id, amount,
               SUM(CASE WHEN status='FAILED' THEN 1 ELSE 0 END) AS failed_count,
               SUM(CASE WHEN status='SUCCESS' THEN 1 ELSE 0 END) AS success_count
        FROM transactions GROUP BY user_id, merchant_id, amount
    )
    WHERE failed_count >= 3 AND success_count >= 1
),
geo_flags AS (
    SELECT DISTINCT t1.user_id, 3 AS risk_points, 'GEO_MISMATCH' AS reason
    FROM transactions t1
    JOIN transactions t2
        ON t1.user_id = t2.user_id AND t1.transaction_id < t2.transaction_id
        AND date(t1.txn_timestamp) = date(t2.txn_timestamp) AND t1.city != t2.city
    WHERE (julianday(t2.txn_timestamp) - julianday(t1.txn_timestamp)) * 24 <= 3
),
all_flags AS (
    SELECT * FROM velocity_flags
    UNION ALL SELECT * FROM oddhour_flags
    UNION ALL SELECT * FROM retry_flags
    UNION ALL SELECT * FROM geo_flags
)
SELECT
    user_id,
    SUM(risk_points) AS total_risk_score,
    GROUP_CONCAT(DISTINCT reason) AS risk_reasons
FROM all_flags
GROUP BY user_id
HAVING total_risk_score >= 3
ORDER BY total_risk_score DESC;
