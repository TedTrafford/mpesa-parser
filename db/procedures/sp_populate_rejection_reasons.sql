-- DBeaver: highlight ONLY from "CREATE DEFINER" through "END;" (last line),
-- then Ctrl+Enter.  Do NOT include these comment lines.
-- Easiest:  python -m db.deploy_procedures

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`sp_populate_rejection_reasons`(
    IN p_mobile_number VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    -- Pin the session collation so string literals (= 'not_qualified',
    -- reason codes, etc.) match the utf8mb4_unicode_ci table columns regardless
    -- of the caller's connection default.  Table columns are aligned by
    -- migration 0018, so column-vs-parameter comparisons also match.
    SET collation_connection = 'utf8mb4_unicode_ci';

    -- -----------------------------------------------------------------------
    -- Reason INSUFFICIENT_HISTORY (rank 1)
    --   Hard gate: no credit limit can be assigned until age_days >= 90.
    --   Idempotent: skips any subscriber that already has this reason_code.
    -- -----------------------------------------------------------------------
    INSERT INTO tbl_rejection_reasons
        (mobile_number, profile_id, reason_rank, reason_code, reason_detail,
         feature_name, feature_value, score_actual, score_max, score_gap,
         repayment_probability)
    WITH cands AS (
        SELECT
            sp.id                AS profile_id,
            sp.mobile_number,
            sp.age_days,
            sp.three_month_wavg,
            sp.turnover_segment,
            sp.risk_segment,
            sp.total_score,
            CASE WHEN sp.age_days IS NULL OR sp.age_days < 90 THEN 1 ELSE 0 END AS has_hist_fail
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM   tbl_subscriber_profiles sp2
            WHERE  sp2.model_category = 'not_qualified'
              AND  (p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number)
        ) sp
        WHERE sp.rn = 1
          AND NOT EXISTS (
              SELECT 1
              FROM   tbl_rejection_reasons rr
              WHERE  rr.mobile_number = sp.mobile_number
                AND  rr.reason_code = 'INSUFFICIENT_HISTORY'
          )
    )
    SELECT
        c.mobile_number,
        c.profile_id,
        1,
        'INSUFFICIENT_HISTORY',
        CONCAT(
            'M-PESA statement history is only ',
            COALESCE(ROUND(c.age_days, 0), 0),
            ' day(s). A minimum of 90 days is required before a credit limit can be assessed.'
        ),
        'age_days',
        c.age_days,
        NULL, NULL, NULL,
        ROUND(100.0 / (1.0 + EXP(-(COALESCE(c.total_score, 0) - 100.0) / 35.0)), 2)
    FROM  cands c
    WHERE c.age_days IS NULL OR c.age_days < 90;

    -- -----------------------------------------------------------------------
    -- Reason HIGH_DEBT_TO_INCOME (rank 1 or 2)
    --   Hard gate: debt-to-income ratio > 50 % (lender inflows account for
    --   more than half of all M-PESA inflows over the last 6 months).
    --   fly_profiling() already forces model_category = 'not_qualified' and
    --   credit_limit = 0 before writing the profile row, so this procedure
    --   only needs to surface the human-readable explanation.
    --   Rank = 1 when no history failure; rank = 2 when history also failed.
    --   Idempotent: skips any subscriber that already has this reason_code.
    -- -----------------------------------------------------------------------
    INSERT INTO tbl_rejection_reasons
        (mobile_number, profile_id, reason_rank, reason_code, reason_detail,
         feature_name, feature_value, score_actual, score_max, score_gap,
         repayment_probability)
    WITH cands AS (
        SELECT
            sp.id                AS profile_id,
            sp.mobile_number,
            sp.age_days,
            sp.total_score,
            sp.total_inflow,
            sp.lender_inflow,
            sp.debt_to_income_ratio,
            CASE WHEN sp.age_days IS NULL OR sp.age_days < 90 THEN 1 ELSE 0 END AS has_hist_fail
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM   tbl_subscriber_profiles sp2
            WHERE  sp2.model_category = 'not_qualified'
              AND  (p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number)
        ) sp
        WHERE sp.rn = 1
          AND sp.debt_to_income_ratio > 0.5000
          AND NOT EXISTS (
              SELECT 1
              FROM   tbl_rejection_reasons rr
              WHERE  rr.mobile_number = sp.mobile_number
                AND  rr.reason_code = 'HIGH_DEBT_TO_INCOME'
          )
    )
    SELECT
        c.mobile_number,
        c.profile_id,
        1 + c.has_hist_fail,
        'HIGH_DEBT_TO_INCOME',
        CONCAT(
            'Debt-to-income ratio is ',
            ROUND(c.debt_to_income_ratio * 100, 1),
            '% — digital-lender inflows (KES ',
            ROUND(COALESCE(c.lender_inflow, 0), 2),
            ') represent more than 50% of total M-PESA inflows (KES ',
            ROUND(COALESCE(c.total_inflow, 0), 2),
            ') over the last 6 months. ',
            'Customers whose inflows are predominantly loan disbursements are ',
            'ineligible for a credit limit until the ratio falls below 50%.'
        ),
        'debt_to_income_ratio',
        c.debt_to_income_ratio,
        NULL, NULL, NULL,
        ROUND(100.0 / (1.0 + EXP(-(COALESCE(c.total_score, 0) - 100.0) / 35.0)), 2)
    FROM  cands c;

    -- -----------------------------------------------------------------------
    -- Reason WEAK_SCORING_FEATURE (rank 1, 2, or 3)
    --   The single scorecard feature with the highest score_gap (most points
    --   lost vs. the theoretical maximum) - the lever with the most room to
    --   improve.  Rank increments by 1 for each active hard gate:
    --     +1 if INSUFFICIENT_HISTORY (age_days < 90)
    --     +1 if HIGH_DEBT_TO_INCOME  (debt_to_income_ratio > 50 %)
    --   Idempotent: skips any subscriber that already has this reason_code.
    -- -----------------------------------------------------------------------
    INSERT INTO tbl_rejection_reasons
        (mobile_number, profile_id, reason_rank, reason_code, reason_detail,
         feature_name, feature_value, score_actual, score_max, score_gap,
         repayment_probability)
    WITH cands AS (
        SELECT
            sp.id                AS profile_id,
            sp.mobile_number,
            sp.age_days,
            sp.three_month_wavg,
            sp.turnover_segment,
            sp.risk_segment,
            sp.total_score,
            CASE WHEN sp.age_days IS NULL OR sp.age_days < 90 THEN 1 ELSE 0 END        AS has_hist_fail,
            CASE WHEN sp.debt_to_income_ratio > 0.5000        THEN 1 ELSE 0 END        AS has_dti_fail
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM   tbl_subscriber_profiles sp2
            WHERE  sp2.model_category = 'not_qualified'
              AND  (p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number)
        ) sp
        WHERE sp.rn = 1
          AND NOT EXISTS (
              SELECT 1
              FROM   tbl_rejection_reasons rr
              WHERE  rr.mobile_number = sp.mobile_number
                AND  rr.reason_code = 'WEAK_SCORING_FEATURE'
          )
    ),
    latest_sf AS (
        SELECT sf.*
        FROM (
            SELECT sf2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sf2.mobile_number
                       ORDER BY     sf2.date_created DESC
                   ) AS rn
            FROM   tbl_scoring_features sf2
            WHERE  sf2.mobile_number IN (SELECT mobile_number FROM cands)
        ) sf
        WHERE sf.rn = 1
    ),
    all_feature_scores AS (
        SELECT mobile_number, feature_name, feature_value, score_actual, score_max,
               (score_max - score_actual) AS score_gap
        FROM (

            -- net_cnt_unq_sender_3m  (max 31, floor -10, range 41 - highest weight)
            SELECT mobile_number,
                   'net_cnt_unq_sender_3m' AS feature_name,
                   net_cnt_unq_sender_3m   AS feature_value,
                   CASE
                       WHEN net_cnt_unq_sender_3m <=  2.5 THEN -10
                       WHEN net_cnt_unq_sender_3m  <  5.5 THEN   5
                       WHEN net_cnt_unq_sender_3m  < 11.0 THEN  10
                       WHEN net_cnt_unq_sender_3m  < 19.5 THEN  17
                       WHEN net_cnt_unq_sender_3m  < 53.0 THEN  27
                       ELSE 31
                   END AS score_actual,
                   31  AS score_max
            FROM latest_sf

            UNION ALL

            -- net_cashflow_6m  (max 31, floor -5, range 36)
            SELECT mobile_number,
                   'net_cashflow_6m',
                   net_cashflow_6m,
                   CASE
                       WHEN net_cashflow_6m <= -771.9 THEN -5
                       WHEN net_cashflow_6m  < -160.6 THEN -1
                       WHEN net_cashflow_6m  <  -18.5 THEN  0
                       WHEN net_cashflow_6m  <    1.5 THEN 10
                       WHEN net_cashflow_6m  <  225.6 THEN 17
                       ELSE 31
                   END,
                   31
            FROM latest_sf

            UNION ALL

            -- flz_sum_amt_6m  (max 35, floor 8, range 27 - highest absolute ceiling)
            SELECT mobile_number,
                   'flz_sum_amt_6m',
                   flz_sum_amt_6m,
                   CASE
                       WHEN flz_sum_amt_6m <= 10    THEN  8
                       WHEN flz_sum_amt_6m  < 18000 THEN 18
                       WHEN flz_sum_amt_6m  < 37140 THEN 28
                       ELSE 35
                   END,
                   35
            FROM latest_sf

            UNION ALL

            -- kplc_paybills_cnt_trns_6m  (max 20, floor -5, range 25)
            SELECT mobile_number,
                   'kplc_paybills_cnt_trns_6m',
                   kplc_paybills_cnt_trns_6m,
                   CASE
                       WHEN kplc_paybills_cnt_trns_6m <= 0.5  THEN -5
                       WHEN kplc_paybills_cnt_trns_6m  < 1.5  THEN  5
                       WHEN kplc_paybills_cnt_trns_6m  < 5.5  THEN 10
                       WHEN kplc_paybills_cnt_trns_6m  < 14.5 THEN 15
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- avg_bal_3m  (max 20, floor -3, range 23)
            SELECT mobile_number,
                   'avg_bal_3m',
                   avg_bal_3m,
                   CASE
                       WHEN avg_bal_3m <=   382.0 THEN -3
                       WHEN avg_bal_3m  <   772.9 THEN  2
                       WHEN avg_bal_3m  <  2179.0 THEN  7
                       WHEN avg_bal_3m  < 19560.0 THEN 13
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- bet_cnt_trns_3m  (max 0, floor -20, range 20 - pure negative impact)
            SELECT mobile_number,
                   'bet_cnt_trns_3m',
                   bet_cnt_trns_3m,
                   CASE
                       WHEN bet_cnt_trns_3m <= 0.5 THEN   0
                       WHEN bet_cnt_trns_3m  < 1.5 THEN   5
                       WHEN bet_cnt_trns_3m  < 8.5 THEN  -8
                       ELSE -20
                   END,
                   0
            FROM latest_sf

            UNION ALL

            -- p2p_received_money_cnt_unq_trns_1m  (max 20, floor 2, range 18)
            SELECT mobile_number,
                   'p2p_received_money_cnt_unq_trns_1m',
                   p2p_received_money_cnt_unq_trns_1m,
                   CASE
                       WHEN p2p_received_money_cnt_unq_trns_1m <= 1.5 THEN  2
                       WHEN p2p_received_money_cnt_unq_trns_1m  < 3.5 THEN 13
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- merch_sum_amt_3m  (max 20, floor 2, range 18)
            SELECT mobile_number,
                   'merch_sum_amt_3m',
                   merch_sum_amt_3m,
                   CASE
                       WHEN merch_sum_amt_3m <=  2020 THEN  2
                       WHEN merch_sum_amt_3m  <  3676 THEN  5
                       WHEN merch_sum_amt_3m  <  6071 THEN  8
                       WHEN merch_sum_amt_3m  <  7366 THEN 10
                       WHEN merch_sum_amt_3m  < 10660 THEN 16
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- all_send_money_sum_amt_3m  (max 20, floor 5, range 15)
            SELECT mobile_number,
                   'all_send_money_sum_amt_3m',
                   all_send_money_sum_amt_3m,
                   CASE
                       WHEN all_send_money_sum_amt_3m <=  19320 THEN  5
                       WHEN all_send_money_sum_amt_3m  <  43460 THEN 10
                       WHEN all_send_money_sum_amt_3m  <  56750 THEN 12
                       WHEN all_send_money_sum_amt_3m  < 113900 THEN 15
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- all_received_money_sum_amt_3m  (max 20, floor 7, range 13)
            SELECT mobile_number,
                   'all_received_money_sum_amt_3m',
                   all_received_money_sum_amt_3m,
                   CASE
                       WHEN all_received_money_sum_amt_3m <=  29990 THEN  7
                       WHEN all_received_money_sum_amt_3m  <  42480 THEN 10
                       WHEN all_received_money_sum_amt_3m  <  50290 THEN 13
                       WHEN all_received_money_sum_amt_3m  < 113800 THEN 15
                       WHEN all_received_money_sum_amt_3m  < 192700 THEN 17
                       ELSE 20
                   END,
                   20
            FROM latest_sf

            UNION ALL

            -- net_banked_6m  (max 20, floor 8, range 12)
            SELECT mobile_number,
                   'net_banked_6m',
                   net_banked_6m,
                   CASE
                       WHEN net_banked_6m <= -179000 THEN 20
                       WHEN net_banked_6m  <  -80490 THEN 17
                       WHEN net_banked_6m  <  -43620 THEN 14
                       WHEN net_banked_6m  <  -16090 THEN 11
                       WHEN net_banked_6m  <   -1650 THEN  9
                       ELSE 8
                   END,
                   20
            FROM latest_sf

        ) unpivoted
    ),
    worst_feature AS (
        SELECT mobile_number, feature_name, feature_value,
               score_actual, score_max, score_gap
        FROM (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY mobile_number
                       ORDER BY score_gap DESC, score_actual ASC
                   ) AS rn
            FROM all_feature_scores
        ) ranked
        WHERE rn = 1
    )
    SELECT
        c.mobile_number,
        c.profile_id,
        1 + c.has_hist_fail + c.has_dti_fail,
        'WEAK_SCORING_FEATURE',
        CONCAT(
            'Scorecard feature "',
            CASE wf.feature_name
                WHEN 'net_cnt_unq_sender_3m'              THEN 'Net unique P2P senders (3 months)'
                WHEN 'net_cashflow_6m'                    THEN 'Net cash flow (6 months)'
                WHEN 'flz_sum_amt_6m'                     THEN 'Fuliza repayments (6 months)'
                WHEN 'kplc_paybills_cnt_trns_6m'          THEN 'KPLC utility payments (6 months)'
                WHEN 'avg_bal_3m'                         THEN 'Average M-PESA balance (3 months)'
                WHEN 'bet_cnt_trns_3m'                    THEN 'Betting transactions (3 months)'
                WHEN 'p2p_received_money_cnt_unq_trns_1m' THEN 'Unique P2P money received (1 month)'
                WHEN 'merch_sum_amt_3m'                   THEN 'Merchant payments (3 months)'
                WHEN 'all_send_money_sum_amt_3m'          THEN 'Total outgoing transfers (3 months)'
                WHEN 'all_received_money_sum_amt_3m'      THEN 'Total incoming transfers (3 months)'
                WHEN 'net_banked_6m'                      THEN 'Net bank deposits (6 months)'
                ELSE wf.feature_name
            END,
            '" scored ', wf.score_actual,
            ' of ', wf.score_max,
            ' possible points (gap: ', wf.score_gap, ' pts; value: ',
            ROUND(wf.feature_value, 2), ').'
        ),
        wf.feature_name,
        wf.feature_value,
        wf.score_actual,
        wf.score_max,
        wf.score_gap,
        ROUND(100.0 / (1.0 + EXP(-(COALESCE(c.total_score, 0) - 100.0) / 35.0)), 2)
    FROM  cands c
    JOIN  worst_feature wf ON wf.mobile_number = c.mobile_number;

    -- -----------------------------------------------------------------------
    -- Reason LOW_TURNOVER (rank 2, 3, or 4)
    --   Applies when age_days >= 90, risk_segment 5-8, but turnover_segment
    --   is still below the minimum required to qualify at that risk level.
    --   Rank increments by 1 for each active hard gate above it:
    --     +1 if INSUFFICIENT_HISTORY (age_days < 90)
    --     +1 if HIGH_DEBT_TO_INCOME  (debt_to_income_ratio > 50 %)
    --
    --   Qualification thresholds (from fly_profiling credit-limit matrix):
    --     risk_segment = 5  -> need turnover_segment >= 8
    --     risk_segment = 6  -> need turnover_segment >= 7
    --     risk_segment = 7  -> need turnover_segment >= 6
    --     risk_segment = 8  -> need turnover_segment >= 5
    --   Idempotent: skips any subscriber that already has this reason_code.
    -- -----------------------------------------------------------------------
    INSERT INTO tbl_rejection_reasons
        (mobile_number, profile_id, reason_rank, reason_code, reason_detail,
         feature_name, feature_value, score_actual, score_max, score_gap,
         repayment_probability)
    WITH cands AS (
        SELECT
            sp.id                AS profile_id,
            sp.mobile_number,
            sp.age_days,
            sp.three_month_wavg,
            sp.turnover_segment,
            sp.risk_segment,
            sp.total_score,
            CASE WHEN sp.age_days IS NULL OR sp.age_days < 90 THEN 1 ELSE 0 END        AS has_hist_fail,
            CASE WHEN sp.debt_to_income_ratio > 0.5000        THEN 1 ELSE 0 END        AS has_dti_fail
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM   tbl_subscriber_profiles sp2
            WHERE  sp2.model_category = 'not_qualified'
              AND  (p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number)
        ) sp
        WHERE sp.rn = 1
          AND NOT EXISTS (
              SELECT 1
              FROM   tbl_rejection_reasons rr
              WHERE  rr.mobile_number = sp.mobile_number
                AND  rr.reason_code = 'LOW_TURNOVER'
          )
    )
    SELECT
        c.mobile_number,
        c.profile_id,
        2 + c.has_hist_fail + c.has_dti_fail,
        'LOW_TURNOVER',
        CONCAT(
            'Three-month weighted average turnover (KES ',
            ROUND(COALESCE(c.three_month_wavg, 0), 2),
            ') places the subscriber in turnover segment ', c.turnover_segment,
            '. At risk segment ', c.risk_segment,
            ', a minimum turnover segment of ',
            CASE c.risk_segment
                WHEN 5 THEN 8
                WHEN 6 THEN 7
                WHEN 7 THEN 6
                WHEN 8 THEN 5
                ELSE 99
            END,
            ' is required to qualify.'
        ),
        'three_month_wavg',
        c.three_month_wavg,
        NULL, NULL, NULL,
        ROUND(100.0 / (1.0 + EXP(-(COALESCE(c.total_score, 0) - 100.0) / 35.0)), 2)
    FROM  cands c
    WHERE (c.age_days IS NULL OR c.age_days >= 90)
      AND c.risk_segment BETWEEN 5 AND 8
      AND c.turnover_segment <
          CASE c.risk_segment
              WHEN 5 THEN 8
              WHEN 6 THEN 7
              WHEN 7 THEN 6
              WHEN 8 THEN 5
              ELSE 99
          END;

    -- -----------------------------------------------------------------------
    -- Reason HIGH_CREDIT_RISK (rank 2, 3, or 4)
    --   Applies when age_days >= 90 but risk_segment <= 4.
    --   The credit-limit matrix only assigns limits from risk segment 5 upward;
    --   no achievable turnover level can qualify this subscriber until the
    --   scorecard score improves.
    --   Rank increments by 1 for each active hard gate above it:
    --     +1 if INSUFFICIENT_HISTORY (age_days < 90)
    --     +1 if HIGH_DEBT_TO_INCOME  (debt_to_income_ratio > 50 %)
    --   Idempotent: skips any subscriber that already has this reason_code.
    -- -----------------------------------------------------------------------
    INSERT INTO tbl_rejection_reasons
        (mobile_number, profile_id, reason_rank, reason_code, reason_detail,
         feature_name, feature_value, score_actual, score_max, score_gap,
         repayment_probability)
    WITH cands AS (
        SELECT
            sp.id                AS profile_id,
            sp.mobile_number,
            sp.age_days,
            sp.three_month_wavg,
            sp.turnover_segment,
            sp.risk_segment,
            sp.total_score,
            CASE WHEN sp.age_days IS NULL OR sp.age_days < 90 THEN 1 ELSE 0 END        AS has_hist_fail,
            CASE WHEN sp.debt_to_income_ratio > 0.5000        THEN 1 ELSE 0 END        AS has_dti_fail
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM   tbl_subscriber_profiles sp2
            WHERE  sp2.model_category = 'not_qualified'
              AND  (p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number)
        ) sp
        WHERE sp.rn = 1
          AND NOT EXISTS (
              SELECT 1
              FROM   tbl_rejection_reasons rr
              WHERE  rr.mobile_number = sp.mobile_number
                AND  rr.reason_code = 'HIGH_CREDIT_RISK'
          )
    )
    SELECT
        c.mobile_number,
        c.profile_id,
        2 + c.has_hist_fail + c.has_dti_fail,
        'HIGH_CREDIT_RISK',
        CONCAT(
            'Total scorecard score is ', COALESCE(c.total_score, 0),
            ' (risk segment ', c.risk_segment, '). ',
            'A minimum risk segment of 5 is required to qualify for any credit limit, ',
            'regardless of turnover level. The subscriber must improve key scoring ',
            'behaviours (see the WEAK_SCORING_FEATURE reason above).'
        ),
        'total_score',
        c.total_score,
        NULL, NULL, NULL,
        ROUND(100.0 / (1.0 + EXP(-(COALESCE(c.total_score, 0) - 100.0) / 35.0)), 2)
    FROM  cands c
    WHERE (c.age_days IS NULL OR c.age_days >= 90)
      AND c.risk_segment <= 4;

END;
