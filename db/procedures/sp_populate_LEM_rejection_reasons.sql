-- DBeaver: highlight ONLY from "CREATE DEFINER" through "END;" (last line),
-- then Ctrl+Enter.  Do NOT include these comment lines.
-- Easiest:  python -m db.deploy_procedures

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`sp_populate_LEM_rejection_reasons`(
    IN p_mobile_number VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
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

    -- Refresh reasons for the evaluation scope (one row per run in enhancements).
    DELETE FROM tbl_LEM_rejection_reasons
    WHERE (p_mobile_number IS NULL OR mobile_number = p_mobile_number);

    DROP TEMPORARY TABLE IF EXISTS tmp_latest_enhancement;
    CREATE TEMPORARY TABLE tmp_latest_enhancement AS
    SELECT e.id, e.customer_id, e.mobile_number, e.is_eligible,
           e.fraud_decision, e.max_arrears_days_1y, e.last_loan_days_late,
           e.debt_to_income_ratio, e.limit_age_days, e.current_limit,
           e.limit_band, e.turnover_segment, e.enhancement_pct
    FROM (
        SELECT e2.*,
               ROW_NUMBER() OVER (
                   PARTITION BY e2.mobile_number
                   ORDER BY     e2.evaluated_at DESC, e2.id DESC
               ) AS rn
        FROM tbl_credit_limit_enhancements e2
        WHERE (p_mobile_number IS NULL OR e2.mobile_number = p_mobile_number)
    ) e
    WHERE e.rn = 1;

    -- -----------------------------------------------------------------------
    -- Shared candidate set: latest ineligible enhancement evaluation per customer
    -- Priority order for ranks:
    --   1 LEM_FRAUD_FLAG
    --   2 LEM_EXCESSIVE_ARREARS
    --   3 LEM_NO_CLOSED_LOAN / LEM_LATE_LOAN_REPAYMENT
    --   4 LEM_HIGH_DEBT_TO_INCOME
    --   5 LEM_LIMIT_TENURE_INSUFFICIENT
    --   6 LEM_NO_MATRIX_CELL
    -- -----------------------------------------------------------------------

    -- Reason LEM_FRAUD_FLAG
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.fraud_decision,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1,
        'LEM_FRAUD_FLAG',
        CONCAT(
            'Fraud evaluation decision is ''', c.fraud_decision,
            '''. Customers flagged for fraud (Reject or Manual Review) are ',
            'ineligible for a credit limit increase until the fraud status clears.'
        ),
        'fraud_decision',
        NULL
    FROM cands c
    WHERE c.fail_fraud = 1;

    -- Reason LEM_EXCESSIVE_ARREARS
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.max_arrears_days_1y,
            e.fraud_decision,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud,
        'LEM_EXCESSIVE_ARREARS',
        CONCAT(
            'A loan in the last 12 months reached ', c.max_arrears_days_1y,
            ' days overdue (maximum permitted: 90 days). ',
            'Limit increases require a clean recent repayment track record.'
        ),
        'max_arrears_days_1y',
        c.max_arrears_days_1y
    FROM cands c
    WHERE c.fail_arrears = 1;

    -- Reason LEM_NO_CLOSED_LOAN
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.fraud_decision,
            e.max_arrears_days_1y,
            e.last_loan_days_late,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears,
            CASE WHEN e.last_loan_days_late IS NULL THEN 1 ELSE 0 END                 AS fail_no_loan
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud + c.fail_arrears,
        'LEM_NO_CLOSED_LOAN',
        'No closed loan on record. A successfully repaid loan is required before a limit increase can be considered.',
        'last_loan_days_late',
        NULL
    FROM cands c
    WHERE c.fail_no_loan = 1;

    -- Reason LEM_LATE_LOAN_REPAYMENT
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.fraud_decision,
            e.max_arrears_days_1y,
            e.last_loan_days_late,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears,
            CASE WHEN e.last_loan_days_late IS NOT NULL AND e.last_loan_days_late > 3 THEN 1 ELSE 0 END AS fail_late
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud + c.fail_arrears,
        'LEM_LATE_LOAN_REPAYMENT',
        CONCAT(
            'Last closed loan was repaid ', c.last_loan_days_late,
            ' day(s) after the final due date. Repayment must be within 3 days of due date to qualify for a limit increase.'
        ),
        'last_loan_days_late',
        c.last_loan_days_late
    FROM cands c
    WHERE c.fail_late = 1;

    -- Reason LEM_HIGH_DEBT_TO_INCOME
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.debt_to_income_ratio,
            e.fraud_decision,
            e.max_arrears_days_1y,
            e.last_loan_days_late,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears,
            CASE WHEN e.last_loan_days_late IS NULL
                  OR e.last_loan_days_late > 3 THEN 1 ELSE 0 END                      AS fail_repay,
            CASE WHEN e.debt_to_income_ratio >= 0.5000 THEN 1 ELSE 0 END            AS fail_dti
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud + c.fail_arrears + c.fail_repay,
        'LEM_HIGH_DEBT_TO_INCOME',
        CONCAT(
            'Debt-to-income ratio is ', ROUND(c.debt_to_income_ratio * 100, 1),
            '% (maximum permitted: 50%). Active reliance on digital-lender inflows ',
            'disqualifies the customer from a limit increase.'
        ),
        'debt_to_income_ratio',
        c.debt_to_income_ratio
    FROM cands c
    WHERE c.fail_dti = 1;

    -- Reason LEM_LIMIT_TENURE_INSUFFICIENT
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.limit_age_days,
            e.fraud_decision,
            e.max_arrears_days_1y,
            e.last_loan_days_late,
            e.debt_to_income_ratio,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears,
            CASE WHEN e.last_loan_days_late IS NULL
                  OR e.last_loan_days_late > 3 THEN 1 ELSE 0 END                      AS fail_repay,
            CASE WHEN e.debt_to_income_ratio >= 0.5000 THEN 1 ELSE 0 END            AS fail_dti,
            CASE WHEN e.limit_age_days IS NULL OR e.limit_age_days < 14 THEN 1 ELSE 0 END AS fail_tenure
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud + c.fail_arrears + c.fail_repay + c.fail_dti,
        'LEM_LIMIT_TENURE_INSUFFICIENT',
        CONCAT(
            'Current credit limit has been held for only ',
            COALESCE(c.limit_age_days, 0),
            ' day(s). A minimum tenure of 14 days on the existing limit is required before an increase.'
        ),
        'limit_age_days',
        c.limit_age_days
    FROM cands c
    WHERE c.fail_tenure = 1;

    -- Reason LEM_NO_MATRIX_CELL
    INSERT INTO tbl_LEM_rejection_reasons
        (mobile_number, customer_id, enhancement_id, reason_rank, reason_code,
         reason_detail, metric_name, metric_value)
    WITH cands AS (
        SELECT
            e.id AS enhancement_id,
            e.mobile_number,
            e.customer_id,
            e.current_limit,
            e.limit_band,
            e.turnover_segment,
            e.enhancement_pct,
            e.fraud_decision,
            e.max_arrears_days_1y,
            e.last_loan_days_late,
            e.debt_to_income_ratio,
            e.limit_age_days,
            CASE WHEN e.fraud_decision IN ('Reject', 'Manual Review') THEN 1 ELSE 0 END AS fail_fraud,
            CASE WHEN COALESCE(e.max_arrears_days_1y, 0) > 90 THEN 1 ELSE 0 END       AS fail_arrears,
            CASE WHEN e.last_loan_days_late IS NULL
                  OR e.last_loan_days_late > 3 THEN 1 ELSE 0 END                      AS fail_repay,
            CASE WHEN e.debt_to_income_ratio >= 0.5000 THEN 1 ELSE 0 END            AS fail_dti,
            CASE WHEN e.limit_age_days IS NULL OR e.limit_age_days < 14 THEN 1 ELSE 0 END AS fail_tenure,
            CASE WHEN e.enhancement_pct IS NULL THEN 1 ELSE 0 END                      AS fail_matrix
        FROM tmp_latest_enhancement e
        WHERE e.is_eligible = 0
    )
    SELECT
        c.mobile_number,
        c.customer_id,
        c.enhancement_id,
        1 + c.fail_fraud + c.fail_arrears + c.fail_repay + c.fail_dti + c.fail_tenure,
        'LEM_NO_MATRIX_CELL',
        CONCAT(
            'No limit increase is defined in the enhancement matrix for limit band ''',
            COALESCE(c.limit_band, 'n/a'),
            ''' (KES ', c.current_limit,
            ') at turnover segment ', COALESCE(c.turnover_segment, 0),
            '. A higher turnover tier or different limit band is required.'
        ),
        'turnover_segment',
        c.turnover_segment
    FROM cands c
    WHERE c.fail_matrix = 1;

END;
