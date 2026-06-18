-- DBeaver: highlight ONLY from "CREATE DEFINER" through "END;" (last line),
-- then Ctrl+Enter.  Do NOT include these comment lines.
-- Easiest:  python -m db.deploy_procedures
--
-- LMS tables are qualified as production.* (customers, loans, repayments).
-- Soft-delete uses deleted_at IS NULL. Approved limits are written to
-- customer_credit_limit only.
-- tbl_credit_limit_enhancements keeps full run history; readers use latest row.
-- proposed_limit = matrix target; enhanced_limit = resulting limit (unchanged if ineligible).

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`sp_apply_credit_limit_enhancement`(
    IN p_mobile_number VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_apply         TINYINT(1)
)
BEGIN

    SET collation_connection = 'utf8mb4_unicode_ci';

    -- MySQL procedure parameters cannot have DEFAULT; treat NULL as evaluate-only.
    IF p_apply IS NULL THEN
        SET p_apply = 0;
    END IF;

    IF p_mobile_number IS NOT NULL THEN
        IF p_mobile_number LIKE '0%' THEN
            SET p_mobile_number = CONCAT('254', SUBSTRING(p_mobile_number, 2));
        ELSEIF p_mobile_number LIKE '+%' THEN
            SET p_mobile_number = SUBSTRING(p_mobile_number, 2);
        END IF;
    END IF;

    INSERT INTO tbl_credit_limit_enhancements (
        customer_id, mobile_number, evaluated_at,
        current_limit, turnover_segment, three_month_wavg,
        limit_band, enhancement_pct, proposed_limit, enhanced_limit, profiling_category,
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
        FROM production.customers c
        WHERE c.deleted_at IS NULL
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
        SELECT customer_id, loan_id, closed_date, last_payment_date, maturity_date
        FROM (
            SELECT
                c.id AS customer_id,
                l.id AS loan_id,
                l.closed_date,
                l.last_payment_date,
                l.maturity_date,
                ROW_NUMBER() OVER (
                    PARTITION BY c.id
                    ORDER BY     l.closed_date DESC, l.id DESC
                ) AS rn
            FROM production.customers c
            INNER JOIN production.loans l ON l.customer_id = c.id
            WHERE c.deleted_at IS NULL
              AND l.deleted_at IS NULL
              AND l.loan_status = 'closed'
        ) x
        WHERE rn = 1
    ),

    last_loan_repayment AS (
        SELECT
            r.loan_id,
            MAX(r.payment_date) AS final_paid_date
        FROM production.repayments r
        WHERE r.deleted_at IS NULL
          AND r.payment_status = 'posted'
        GROUP BY r.loan_id
    ),

    last_loan_payment AS (
        SELECT
            ll.customer_id,
            ll.maturity_date AS final_due_date,
            COALESCE(
                lr.final_paid_date,
                DATE(ll.closed_date),
                DATE(ll.last_payment_date)
            ) AS final_paid_date
        FROM last_loan ll
        LEFT JOIN last_loan_repayment lr ON lr.loan_id = ll.loan_id
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
            c.id AS customer_id,
            MAX(l.days_overdue) AS max_arrears_days
        FROM production.customers c
        INNER JOIN production.loans l ON l.customer_id = c.id
        WHERE c.deleted_at IS NULL
          AND l.deleted_at IS NULL
          AND l.disbursement_date >= DATE_SUB(CURDATE(), INTERVAL 1 YEAR)
        GROUP BY c.id
    ),

    gate_arrears AS (
        SELECT
            s.customer_id,
            COALESCE(a.max_arrears_days, 0) AS max_arrears_days,
            (COALESCE(a.max_arrears_days, 0) <= 90) AS passed
        FROM scope s
        LEFT JOIN arrears_1y a ON a.customer_id = s.customer_id
    ),

    closed_loans AS (
        SELECT
            c.id AS customer_id,
            COUNT(l.id) AS closed_loan_count
        FROM production.customers c
        INNER JOIN production.loans l ON l.customer_id = c.id
        WHERE c.deleted_at IS NULL
          AND l.deleted_at IS NULL
          AND l.loan_status = 'closed'
        GROUP BY c.id
    ),

    prior_revision AS (
        SELECT
            e.mobile_number,
            COALESCE(MAX(
                CAST(REGEXP_REPLACE(e.profiling_category, '[^0-9]', '') AS UNSIGNED)
            ), 0) AS last_revision
        FROM tbl_credit_limit_enhancements e
        WHERE e.applied = 1
          AND e.profiling_category LIKE 'ENHANCED\_%'
        GROUP BY e.mobile_number
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
            COALESCE(cl.closed_loan_count, 0) AS closed_loan_count,

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
        LEFT JOIN closed_loans cl       ON cl.customer_id     = lim.customer_id
    ),

    scored AS (
        SELECT
            e.*,
            CONCAT('ENHANCED_', COALESCE(pr.last_revision, 0) + 1) AS profiling_category,

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
            ) AS elig_gate5,
            (e.closed_loan_count >= 3) AS elig_gate6

        FROM evaluated e
        LEFT JOIN prior_revision pr ON pr.mobile_number = e.mobile_number
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
        CASE
            WHEN enhancement_pct IS NOT NULL
             AND elig_gate1 AND elig_gate2 AND elig_gate3 AND elig_gate4 AND elig_gate5
             AND elig_gate6
            THEN ROUND(current_limit * (1 + enhancement_pct))
            ELSE current_limit
        END,
        profiling_category,
        (
            elig_gate1 AND elig_gate2 AND elig_gate3 AND elig_gate4 AND elig_gate5
            AND elig_gate6
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
            CASE WHEN NOT elig_gate6 THEN CONCAT(
                'Fewer than 3 closed loans on record (',
                closed_loan_count,
                ' closed). First limit increase requires at least 3 repaid loans'
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

    -- Surface ranked reasons for ineligible customers.
    CALL sp_populate_LEM_rejection_reasons(p_mobile_number);

    IF p_apply = 1 THEN
        DELETE ccl
        FROM   customer_credit_limit ccl
        INNER JOIN tbl_credit_limit_enhancements e
                ON e.mobile_number = ccl.mobile_number
        INNER JOIN (
            SELECT mobile_number, MAX(id) AS latest_id
            FROM   tbl_credit_limit_enhancements
            WHERE  (p_mobile_number IS NULL OR mobile_number = p_mobile_number)
            GROUP  BY mobile_number
        ) latest ON latest.latest_id = e.id
        WHERE  e.is_eligible    = 1
          AND  e.proposed_limit IS NOT NULL
          AND  e.proposed_limit > e.current_limit
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number);

        INSERT INTO customer_credit_limit (
            mobile_number, credit_limit, profiling_date, profiling_category
        )
        SELECT
            e.mobile_number,
            e.proposed_limit,
            NOW(),
            e.profiling_category
        FROM tbl_credit_limit_enhancements e
        INNER JOIN (
            SELECT mobile_number, MAX(id) AS latest_id
            FROM   tbl_credit_limit_enhancements
            WHERE  (p_mobile_number IS NULL OR mobile_number = p_mobile_number)
            GROUP  BY mobile_number
        ) latest ON latest.latest_id = e.id
        WHERE  e.is_eligible    = 1
          AND  e.proposed_limit IS NOT NULL
          AND  e.proposed_limit > e.current_limit
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number);

        UPDATE tbl_credit_limit_enhancements e
        INNER JOIN (
            SELECT mobile_number, MAX(id) AS latest_id
            FROM   tbl_credit_limit_enhancements
            WHERE  (p_mobile_number IS NULL OR mobile_number = p_mobile_number)
            GROUP  BY mobile_number
        ) latest ON latest.latest_id = e.id
        SET    e.applied    = 1,
               e.applied_at = NOW()
        WHERE  e.is_eligible    = 1
          AND  e.proposed_limit IS NOT NULL
          AND  e.proposed_limit > e.current_limit
          AND  (p_mobile_number IS NULL OR e.mobile_number = p_mobile_number);
    END IF;

END;
