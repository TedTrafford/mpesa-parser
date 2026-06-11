-- DBeaver: highlight ONLY from "CREATE DEFINER" through "END;" (last line),
-- then Ctrl+Enter.  Do NOT include these comment lines.
-- Easiest:  python -m db.deploy_procedures
--
-- LMS tables are qualified as aleza.* (customers, loans, loan_schedules,
-- credit_profiles). Change the prefix if your live-app database name differs.

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`sp_apply_credit_limit_enhancement`(
    IN p_mobile_number VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_apply         TINYINT(1)   DEFAULT 0
)
BEGIN

    SET collation_connection = 'utf8mb4_unicode_ci';

    IF p_mobile_number IS NOT NULL THEN
        IF p_mobile_number LIKE '0%' THEN
            SET p_mobile_number = CONCAT('254', SUBSTRING(p_mobile_number, 2));
        ELSEIF p_mobile_number LIKE '+%' THEN
            SET p_mobile_number = SUBSTRING(p_mobile_number, 2);
        END IF;
    END IF;

    DELETE FROM tbl_credit_limit_enhancements
    WHERE (p_mobile_number IS NULL OR mobile_number = p_mobile_number);

    INSERT INTO tbl_credit_limit_enhancements (
        customer_id, mobile_number, evaluated_at,
        current_limit, turnover_segment, three_month_wavg,
        limit_band, enhancement_pct, enhanced_limit,
        is_eligible, eligibility_detail, applied,
        last_loan_days_late, max_arrears_days_1y, limit_age_days,
        fraud_decision, debt_to_income_ratio
    )
    WITH
    scope AS (
        SELECT
            c.id AS customer_id,
            CASE
                WHEN c.phone_number LIKE '0%'  THEN CONCAT('254', SUBSTRING(c.phone_number, 2))
                WHEN c.phone_number LIKE '+%'  THEN SUBSTRING(c.phone_number, 2)
                ELSE TRIM(c.phone_number)
            END AS mobile_number
        FROM aleza.customers c
        WHERE (c.soft_delete IS NULL OR c.soft_delete = 0)
          AND COALESCE(c.is_active, 1) = 1
          AND COALESCE(c.blacklisted, 0) = 0
    ),

    limits AS (
        SELECT
            s.customer_id,
            s.mobile_number,
            ccl.credit_limit  AS current_limit,
            ccl.profiling_date
        FROM scope s
        INNER JOIN customer_credit_limit ccl
                ON ccl.mobile_number = s.mobile_number
        WHERE ccl.credit_limit >= 1000
          AND (p_mobile_number IS NULL OR s.mobile_number = p_mobile_number)
    ),

    profile AS (
        SELECT
            sp.mobile_number,
            sp.three_month_wavg,
            sp.debt_to_income_ratio,
            sp.turnover_segment AS stored_turnover_segment
        FROM (
            SELECT sp2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY sp2.mobile_number
                       ORDER BY     sp2.last_updated DESC
                   ) AS rn
            FROM tbl_subscriber_profiles sp2
        ) sp
        WHERE sp.rn = 1
    ),

    fraud AS (
        SELECT f.mobile_number, f.decision
        FROM (
            SELECT f2.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY f2.mobile_number
                       ORDER BY     f2.evaluated_at DESC
                   ) AS rn
            FROM tbl_fraud_rules f2
        ) f
        WHERE f.rn = 1
    ),

    last_loan AS (
        SELECT customer_id, loan_id, closed_date, last_payment_date
        FROM (
            SELECT
                l.customer_id,
                l.id AS loan_id,
                l.closed_date,
                l.last_payment_date,
                ROW_NUMBER() OVER (
                    PARTITION BY l.customer_id
                    ORDER BY     l.closed_date DESC, l.id DESC
                ) AS rn
            FROM aleza.loans l
            WHERE l.loan_status = 'closed'
              AND (l.soft_delete IS NULL OR l.soft_delete = 0)
        ) x
        WHERE rn = 1
    ),

    last_loan_payment AS (
        SELECT
            ll.customer_id,
            fin.due_date AS final_due_date,
            COALESCE(
                fin.paid_date,
                DATE(ll.closed_date),
                DATE(ll.last_payment_date)
            ) AS final_paid_date
        FROM last_loan ll
        JOIN LATERAL (
            SELECT ls.due_date, ls.paid_date
            FROM   aleza.loan_schedules ls
            WHERE  ls.loan_id = ll.loan_id
              AND  (ls.soft_delete IS NULL OR ls.soft_delete = 0)
            ORDER  BY ls.installment_number DESC
            LIMIT  1
        ) fin ON TRUE
    ),

    gate_last_payment AS (
        SELECT
            customer_id,
            GREATEST(0, DATEDIFF(final_paid_date, final_due_date)) AS days_late,
            (final_paid_date <= final_due_date + INTERVAL 3 DAY)   AS passed
        FROM last_loan_payment
    ),

    arrears_1y AS (
        SELECT
            l.customer_id,
            MAX(ls.days_overdue) AS max_arrears_days
        FROM aleza.loans l
        INNER JOIN aleza.loan_schedules ls ON ls.loan_id = l.id
        WHERE (l.soft_delete IS NULL OR l.soft_delete = 0)
          AND (ls.soft_delete IS NULL OR ls.soft_delete = 0)
          AND l.disbursement_date >= DATE_SUB(CURDATE(), INTERVAL 1 YEAR)
        GROUP BY l.customer_id
    ),

    gate_arrears AS (
        SELECT
            s.customer_id,
            COALESCE(a.max_arrears_days, 0) AS max_arrears_days,
            (COALESCE(a.max_arrears_days, 0) <= 90) AS passed
        FROM scope s
        LEFT JOIN arrears_1y a ON a.customer_id = s.customer_id
    ),

    evaluated AS (
        SELECT
            lim.customer_id,
            lim.mobile_number,
            lim.current_limit,
            lim.profiling_date,

            COALESCE(
                prof.stored_turnover_segment,
                CASE
                    WHEN prof.three_month_wavg IS NULL   THEN 0
                    WHEN prof.three_month_wavg <=   9841 THEN 1
                    WHEN prof.three_month_wavg <=  12561 THEN 2
                    WHEN prof.three_month_wavg <=  16027 THEN 3
                    WHEN prof.three_month_wavg <=  23895 THEN 4
                    WHEN prof.three_month_wavg <=  39179 THEN 5
                    WHEN prof.three_month_wavg <=  60463 THEN 6
                    WHEN prof.three_month_wavg <= 107556 THEN 7
                    ELSE 8
                END
            ) AS turnover_segment,

            prof.three_month_wavg,
            prof.debt_to_income_ratio,

            CASE
                WHEN lim.current_limit BETWEEN  1000 AND  5000 THEN '1k_5k'
                WHEN lim.current_limit BETWEEN  5001 AND 10000 THEN '5k_10k'
                WHEN lim.current_limit BETWEEN 10001 AND 20000 THEN '10k_20k'
                WHEN lim.current_limit BETWEEN 20001 AND 30000 THEN '20k_30k'
                WHEN lim.current_limit BETWEEN 30001 AND 40000 THEN '30k_40k'
                ELSE NULL
            END AS limit_band,

            glp.days_late AS last_loan_days_late,
            COALESCE(glp.passed, 0) AS gate1_passed,
            gar.max_arrears_days AS max_arrears_days_1y,
            COALESCE(gar.passed, 1) AS gate2_passed,

            CASE
                WHEN lim.profiling_date IS NOT NULL
                THEN DATEDIFF(CURDATE(), DATE(lim.profiling_date))
                ELSE NULL
            END AS limit_age_days,

            fr.decision AS fraud_decision

        FROM limits lim
        LEFT JOIN profile prof          ON prof.mobile_number = lim.mobile_number
        LEFT JOIN fraud fr              ON fr.mobile_number   = lim.mobile_number
        LEFT JOIN gate_last_payment glp ON glp.customer_id    = lim.customer_id
        INNER JOIN gate_arrears gar     ON gar.customer_id    = lim.customer_id
    ),

    scored AS (
        SELECT
            e.*,

            CASE e.limit_band
                WHEN '30k_40k' THEN CASE e.turnover_segment
                    WHEN 8 THEN 0.10 WHEN 7 THEN 0.05 END
                WHEN '20k_30k' THEN CASE e.turnover_segment
                    WHEN 8 THEN 0.20 WHEN 7 THEN 0.10 WHEN 6 THEN 0.05 END
                WHEN '10k_20k' THEN CASE e.turnover_segment
                    WHEN 8 THEN 0.30 WHEN 7 THEN 0.20 WHEN 6 THEN 0.08 WHEN 5 THEN 0.10 END
                WHEN '5k_10k' THEN CASE e.turnover_segment
                    WHEN 8 THEN 0.40 WHEN 7 THEN 0.30 WHEN 6 THEN 0.20
                    WHEN 5 THEN 0.15 WHEN 4 THEN 0.03 END
                WHEN '1k_5k' THEN CASE e.turnover_segment
                    WHEN 8 THEN 0.60 WHEN 7 THEN 0.50 WHEN 6 THEN 0.50 WHEN 5 THEN 0.40
                    WHEN 4 THEN 0.30 WHEN 3 THEN 0.20 WHEN 2 THEN 0.05 END
                ELSE NULL
            END AS enhancement_pct,

            (e.gate1_passed = 1) AS elig_gate1,
            (e.gate2_passed = 1) AS elig_gate2,
            (e.limit_age_days IS NOT NULL AND e.limit_age_days >= 14) AS elig_gate3,
            (
                e.fraud_decision IS NULL
                OR e.fraud_decision NOT IN ('Reject', 'Manual Review')
            ) AS elig_gate4,
            (
                e.debt_to_income_ratio IS NULL
                OR e.debt_to_income_ratio < 0.5000
            ) AS elig_gate5

        FROM evaluated e
    )
    SELECT
        customer_id,
        mobile_number,
        NOW(),
        current_limit,
        turnover_segment,
        three_month_wavg,
        limit_band,
        ROUND(enhancement_pct * 100, 2),
        CASE
            WHEN enhancement_pct IS NOT NULL
            THEN ROUND(current_limit * (1 + enhancement_pct))
            ELSE NULL
        END,
        (
            elig_gate1 AND elig_gate2 AND elig_gate3 AND elig_gate4 AND elig_gate5
            AND enhancement_pct IS NOT NULL
        ),
        CONCAT_WS('; ',
            CASE WHEN NOT elig_gate1 THEN
                CASE
                    WHEN last_loan_days_late IS NULL
                        THEN 'No closed loan on record'
                    ELSE CONCAT(
                        'Last loan not repaid within 3 days of due date (paid ',
                        last_loan_days_late, ' day(s) late)'
                    )
                END
            END,
            CASE WHEN NOT elig_gate2 THEN CONCAT(
                'Loan in last 12 months exceeded 90 days arrears (max ',
                max_arrears_days_1y, ' days)'
            ) END,
            CASE WHEN NOT elig_gate3 THEN CONCAT(
                'Credit limit held for less than 14 days (',
                COALESCE(limit_age_days, 0), ' day(s))'
            ) END,
            CASE WHEN NOT elig_gate4 THEN CONCAT(
                'Fraud flag active (decision: ', COALESCE(fraud_decision, 'n/a'), ')'
            ) END,
            CASE WHEN NOT elig_gate5 THEN CONCAT(
                'Debt-to-income ratio >= 50% (',
                ROUND(COALESCE(debt_to_income_ratio, 0) * 100, 1), '%)'
            ) END,
            CASE WHEN enhancement_pct IS NULL THEN CONCAT(
                'No enhancement in matrix for limit band ',
                COALESCE(limit_band, 'n/a'),
                ' x turnover segment ',
                COALESCE(turnover_segment, 0)
            ) END
        ),
        0,
        last_loan_days_late,
        max_arrears_days_1y,
        limit_age_days,
        fraud_decision,
        debt_to_income_ratio
    FROM scored;

    IF p_apply = 1 THEN
        UPDATE aleza.credit_profiles cp
        INNER JOIN tbl_credit_limit_enhancements e
                ON e.customer_id = cp.customer_id
        SET    cp.credit_limit     = e.enhanced_limit,
               cp.available_credit = GREATEST(
                   0,
                   e.enhanced_limit - COALESCE(cp.outstanding_balance, 0)
               ),
               cp.updated_at       = NOW()
        WHERE  e.is_eligible    = 1
          AND  e.enhanced_limit IS NOT NULL
          AND  e.enhanced_limit > e.current_limit
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number)
          AND  (cp.soft_delete IS NULL OR cp.soft_delete = 0);

        UPDATE customer_credit_limit ccl
        INNER JOIN tbl_credit_limit_enhancements e
                ON e.mobile_number = ccl.mobile_number
        SET    ccl.credit_limit       = e.enhanced_limit,
               ccl.profiling_date     = NOW(),
               ccl.profiling_category = 'ENHANCED'
        WHERE  e.is_eligible    = 1
          AND  e.enhanced_limit IS NOT NULL
          AND  e.enhanced_limit > e.current_limit
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number);

        UPDATE tbl_credit_limit_enhancements e
        SET    e.applied    = 1,
               e.applied_at = NOW()
        WHERE  e.is_eligible = 1
          AND  e.enhanced_limit IS NOT NULL
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number);
    END IF;

END;
