DROP PROCEDURE IF EXISTS `Data_Science`.`fly_profiling`;

DELIMITER $$

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`fly_profiling`(
    IN  ip_mobile_number  VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    DECLARE update_check              DOUBLE   DEFAULT NULL;
    DECLARE month1                    DOUBLE   DEFAULT NULL;
    DECLARE month2                    DOUBLE   DEFAULT NULL;
    DECLARE month3                    DOUBLE   DEFAULT NULL;
    DECLARE age_days                  DOUBLE   DEFAULT NULL;
    DECLARE three_month_wavg          DOUBLE   DEFAULT NULL;
    DECLARE var_credit_limit          INT      DEFAULT 0;
    DECLARE risk_score                DOUBLE   DEFAULT NULL;
    DECLARE risk_segment              BIGINT   DEFAULT 0;
    DECLARE model_category            TEXT     DEFAULT NULL;
    DECLARE turnover_segment          DOUBLE   DEFAULT 0;

    -- DTI variables (6-month window, digital-lender dictionary)
    DECLARE var_total_inflow              DOUBLE   DEFAULT NULL;
    DECLARE var_lender_inflow             DOUBLE   DEFAULT NULL;
    DECLARE var_debt_to_income_ratio      DOUBLE   DEFAULT NULL;
    DECLARE var_total_inflow_txn_count    BIGINT   DEFAULT 0;
    DECLARE var_lender_inflow_txn_count   BIGINT   DEFAULT 0;

    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    -- -------------------------------------------------------------------------
    -- Normalise the input to the international format (254xxx).
    -- Handles three forms:
    --   '0722123456'    -> '254722123456'   local trunk prefix
    --   '+254722123456' -> '254722123456'   E.164 with leading '+'
    --   '254722123456'  -> '254722123456'   already normalised (no-op)
    -- -------------------------------------------------------------------------
    IF ip_mobile_number LIKE '0%' THEN
        SET ip_mobile_number = CONCAT('254', SUBSTRING(ip_mobile_number, 2));
    ELSEIF ip_mobile_number LIKE '+%' THEN
        SET ip_mobile_number = SUBSTRING(ip_mobile_number, 2);
    END IF;

    -- CONCAT/SUBSTRING and string literals above inherit the connection
    -- collation (utf8mb4_0900_ai_ci on MySQL 8), which clashes with the
    -- utf8mb4_unicode_ci columns and raises Error 1267 on every later
    -- `mobile_number = ip_mobile_number` comparison.  Pin the value back to
    -- the schema collation so all comparisons below use one consistent one.
    SET ip_mobile_number = ip_mobile_number COLLATE utf8mb4_unicode_ci;

    SELECT mobile_number INTO update_check
    FROM   customer_credit_limit
    WHERE  mobile_number = ip_mobile_number
    LIMIT  1;

    SET month1 = (
        SELECT COALESCE(SUM(amount), 0)
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number    = ip_mobile_number
          AND  amount           > 0
        GROUP  BY DATE_FORMAT(transaction_date, '%Y-%m')
        ORDER  BY DATE_FORMAT(transaction_date, '%Y-%m') DESC
        LIMIT  1
    );

    SET month2 = (
        SELECT COALESCE(SUM(amount), 0)
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number    = ip_mobile_number
          AND  amount           > 0
        GROUP  BY DATE_FORMAT(transaction_date, '%Y-%m')
        ORDER  BY DATE_FORMAT(transaction_date, '%Y-%m') DESC
        LIMIT  1 OFFSET 1
    );

    SET month3 = (
        SELECT COALESCE(SUM(amount), 0)
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number    = ip_mobile_number
          AND  amount           > 0
        GROUP  BY DATE_FORMAT(transaction_date, '%Y-%m')
        ORDER  BY DATE_FORMAT(transaction_date, '%Y-%m') DESC
        LIMIT  1 OFFSET 2
    );

    SET age_days = (
        SELECT DATEDIFF(CURDATE(), DATE(MIN(transaction_date)))
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number = ip_mobile_number
    );

    -- -------------------------------------------------------------------------
    -- Debt-to-income ratio (6-month window)
    -- Classify each positive transaction against the digital-lender dictionary
    -- in a single table scan; derive the ratio from the aggregates.
    -- -------------------------------------------------------------------------
    SELECT
        COALESCE(SUM(amount),                                    0),
        COALESCE(SUM(CASE WHEN is_lender THEN amount ELSE 0 END), 0),
        COUNT(*),
        COALESCE(SUM(CASE WHEN is_lender THEN 1     ELSE 0 END), 0)
    INTO
        var_total_inflow,
        var_lender_inflow,
        var_total_inflow_txn_count,
        var_lender_inflow_txn_count
    FROM (
        SELECT
            amount,
            (    details LIKE '%overdraft of credit party%'
              OR details LIKE '%m-pesa overdraw%'
              OR details LIKE '%od loan%'
              OR details LIKE '%tala loan%'
              OR details LIKE '%branch microfinance%'
              OR details LIKE '%zenka digital%'
              OR details LIKE '%timiza%'
              OR details LIKE '%m-kopa%'
              OR details LIKE '%h- fund%'
              OR details LIKE '%h-fund%'
              OR details LIKE '%hustler fund%'
              OR details LIKE '%hfund savings%'
              OR details LIKE '%term loan disbursement%'
              OR details LIKE '%loop b2c%'
              OR details LIKE '%loop business%'
              OR details LIKE '%zash loan%'
              OR details LIKE '%zillions credit%'
              OR details LIKE '%chelete credit%'
              OR details LIKE '%payablu credit%'
              OR details LIKE '%chapeo capital%'
              OR details LIKE '%creditarea capital%'
              OR details LIKE '%loan plus digital%'
              OR details LIKE '%simplepay capital%'
              OR details LIKE '%ceres tech%'
              OR details LIKE '%zamaradi capital%'
              OR details LIKE '%fourth generation capital%'
              OR details LIKE '%mular credit%'
              OR details LIKE '%ajax credit%'
              OR details LIKE '%mkulimapay credit%'
              OR details LIKE '%risine credit%'
              OR details LIKE '%pesa kuu credit%'
              OR details LIKE '%goldstep capital%'
              OR details LIKE '%azura credit%'
              OR details LIKE '%flashpesa%'
              OR details LIKE '%impala credit%'
              OR details LIKE '%platinum credit%'
              OR details LIKE '%bytech credit%'
              OR details LIKE '%getcash capital%'
              OR details LIKE '%milestone credit%'
              OR details LIKE '%marble capital%'
              OR details LIKE '%sure cred capital%'
              OR details LIKE '%finberry capital%'
              OR details LIKE '%inspire credit%'
              OR details LIKE '%fast credit%'
              OR details LIKE '%brisk credit%'
              OR details LIKE '%okash%'
              OR details LIKE '%mshwari%'
              OR details LIKE '%fairmoney%'
              OR details LIKE '%ipesa%'
              OR details LIKE '%kopesh%'
              OR details LIKE '%lendplus%'
              OR details LIKE '%opesa%'
            ) AS is_lender
        FROM tbl_raw_mpesa_statements
        WHERE mobile_number     = ip_mobile_number
          AND amount            > 0
          AND transaction_date >= DATE_SUB(CURDATE(), INTERVAL 6 MONTH)
    ) dti_src;

    SET var_debt_to_income_ratio = CASE
        WHEN var_total_inflow IS NULL OR var_total_inflow = 0 THEN NULL
        ELSE ROUND(var_lender_inflow / var_total_inflow, 4)
    END;

    SET three_month_wavg = (
        (COALESCE(month1, 0) * 3 +
         COALESCE(month2, 0) * 2 +
         COALESCE(month3, 0) * 1) / 6
    );

    INSERT INTO tbl_scoring_features
        (mobile_number, date_created,
         flz_sum_amt_6m,                 kplc_paybills_cnt_trns_6m,
         all_received_money_sum_amt_6m,  all_send_money_sum_amt_6m,
         p2p_send_money_cnt_unq_trns_3m, p2p_received_money_cnt_unq_trns_3m,
         bank_deposit_sum_amt_6m,        p2p_received_money_sum_amt_6m,
         all_received_money_sum_amt_3m,  all_send_money_sum_amt_3m,
         p2p_received_money_cnt_unq_trns_1m,
         avg_bal_3m, merch_sum_amt_3m,   bet_cnt_trns_3m,
         net_cashflow_6m, net_cnt_unq_sender_3m, net_banked_6m)
    WITH max_date AS (
        SELECT MAX(transaction_date) AS max_transaction_date
        FROM   tbl_raw_mpesa_statements
    ),
    all_features AS (
        SELECT
            mobile_number,
            NOW() AS date_created,
            COALESCE(SUM(CASE
                WHEN transaction_type LIKE '%OTHER%'
                 AND details          LIKE '%Fuliza%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN ABS(amount) ELSE 0 END), 0)                              AS flz_sum_amt_6m,
            COUNT(DISTINCT CASE
                WHEN transaction_type LIKE '%PAYBILL%'
                 AND details          LIKE '%KPLC%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN receipt_no END)                                          AS kplc_paybills_cnt_trns_6m,
            COALESCE(SUM(CASE
                WHEN transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                 AND amount > 0
                THEN amount ELSE 0 END), 0)                                   AS all_received_money_sum_amt_6m,
            COALESCE(SUM(CASE
                WHEN transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                 AND amount < 0
                THEN ABS(amount) ELSE 0 END), 0)                              AS all_send_money_sum_amt_6m,
            COUNT(DISTINCT CASE
                WHEN transaction_type LIKE '%SEND MONEY%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN details END)                                             AS p2p_send_money_cnt_unq_trns_3m,
            COUNT(DISTINCT CASE
                WHEN transaction_type LIKE '%RECEIVED MONEY%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN details END)                                             AS p2p_received_money_cnt_unq_trns_3m,
            COALESCE(SUM(CASE
                WHEN transaction_type LIKE '%OTHER%'
                 AND details          LIKE '%Bank%'
                 AND amount < 0
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN ABS(amount) ELSE 0 END), 0)                              AS bank_deposit_sum_amt_6m,
            COALESCE(SUM(CASE
                WHEN transaction_type LIKE '%RECEIVED MONEY%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 180 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN amount ELSE 0 END), 0)                                   AS p2p_received_money_sum_amt_6m,
            COALESCE(SUM(CASE
                WHEN transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                 AND amount > 0
                THEN amount ELSE 0 END), 0)                                   AS all_received_money_sum_amt_3m,
            COALESCE(SUM(CASE
                WHEN transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                 AND amount < 0
                THEN ABS(amount) ELSE 0 END), 0)                              AS all_send_money_sum_amt_3m,
            COUNT(DISTINCT CASE
                WHEN transaction_type LIKE '%RECEIVED MONEY%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 30 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN details END)                                             AS p2p_received_money_cnt_unq_trns_1m,
            COALESCE(AVG(CASE
                WHEN transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN balance END), 0)                                         AS avg_bal_3m,
            COALESCE(SUM(CASE
                WHEN transaction_type LIKE '%OTHER%'
                 AND details          LIKE '%Merchant Payment%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN ABS(amount) ELSE 0 END), 0)                              AS merch_sum_amt_3m,
            COUNT(DISTINCT CASE
                WHEN transaction_type LIKE '%OTHER%'
                 AND details          LIKE '%BET%'
                 AND transaction_date >= DATE_SUB((SELECT max_transaction_date FROM max_date), INTERVAL 90 DAY)
                 AND transaction_date <  (SELECT max_transaction_date FROM max_date)
                THEN receipt_no END)                                          AS bet_cnt_trns_3m
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number = ip_mobile_number
        GROUP  BY mobile_number
    ),
    derived_features AS (
        SELECT *,
            all_received_money_sum_amt_6m  - all_send_money_sum_amt_6m           AS net_cashflow_6m,
            p2p_send_money_cnt_unq_trns_3m - p2p_received_money_cnt_unq_trns_3m  AS net_cnt_unq_sender_3m,
            bank_deposit_sum_amt_6m        - p2p_received_money_sum_amt_6m       AS net_banked_6m
        FROM all_features
    )
    SELECT
        mobile_number, date_created,
        flz_sum_amt_6m,                 kplc_paybills_cnt_trns_6m,
        all_received_money_sum_amt_6m,  all_send_money_sum_amt_6m,
        p2p_send_money_cnt_unq_trns_3m, p2p_received_money_cnt_unq_trns_3m,
        bank_deposit_sum_amt_6m,        p2p_received_money_sum_amt_6m,
        all_received_money_sum_amt_3m,  all_send_money_sum_amt_3m,
        p2p_received_money_cnt_unq_trns_1m,
        avg_bal_3m, merch_sum_amt_3m,   bet_cnt_trns_3m,
        net_cashflow_6m, net_cnt_unq_sender_3m, net_banked_6m
    FROM derived_features;

    SELECT SUM(
        CASE
            WHEN flz_sum_amt_6m <=    10                             THEN  8
            WHEN flz_sum_amt_6m  <  18000                            THEN 18
            WHEN flz_sum_amt_6m  <  37140                            THEN 28
            ELSE                                                           35
        END +
        CASE
            WHEN kplc_paybills_cnt_trns_6m <=  0.5                   THEN  -5
            WHEN kplc_paybills_cnt_trns_6m  <  1.5                   THEN   5
            WHEN kplc_paybills_cnt_trns_6m  <  5.5                   THEN  10
            WHEN kplc_paybills_cnt_trns_6m  < 14.5                   THEN  15
            ELSE                                                            20
        END +
        CASE
            WHEN net_cashflow_6m <= -771.9                            THEN  -5
            WHEN net_cashflow_6m  < -160.6                            THEN  -1
            WHEN net_cashflow_6m  <  -18.5                            THEN   0
            WHEN net_cashflow_6m  <    1.5                            THEN  10
            WHEN net_cashflow_6m  <  225.6                            THEN  17
            ELSE                                                            31
        END +
        CASE
            WHEN net_cnt_unq_sender_3m <=  2.5                        THEN -10
            WHEN net_cnt_unq_sender_3m  <  5.5                        THEN   5
            WHEN net_cnt_unq_sender_3m  < 11.0                        THEN  10
            WHEN net_cnt_unq_sender_3m  < 19.5                        THEN  17
            WHEN net_cnt_unq_sender_3m  < 53.0                        THEN  27
            ELSE                                                            31
        END +
        CASE
            WHEN net_banked_6m <= -179000                             THEN  20
            WHEN net_banked_6m  <  -80490                             THEN  17
            WHEN net_banked_6m  <  -43620                             THEN  14
            WHEN net_banked_6m  <  -16090                             THEN  11
            WHEN net_banked_6m  <   -1650                             THEN   9
            ELSE                                                             8
        END +
        CASE
            WHEN all_received_money_sum_amt_3m <=  29990              THEN   7
            WHEN all_received_money_sum_amt_3m  <  42480              THEN  10
            WHEN all_received_money_sum_amt_3m  <  50290              THEN  13
            WHEN all_received_money_sum_amt_3m  < 113800              THEN  15
            WHEN all_received_money_sum_amt_3m  < 192700              THEN  17
            ELSE                                                            20
        END +
        CASE
            WHEN all_send_money_sum_amt_3m <=  19320                  THEN   5
            WHEN all_send_money_sum_amt_3m  <  43460                  THEN  10
            WHEN all_send_money_sum_amt_3m  <  56750                  THEN  12
            WHEN all_send_money_sum_amt_3m  < 113900                  THEN  15
            ELSE                                                            20
        END +
        CASE
            WHEN p2p_received_money_cnt_unq_trns_1m <= 1.5            THEN   2
            WHEN p2p_received_money_cnt_unq_trns_1m  < 3.5            THEN  13
            ELSE                                                            20
        END +
        CASE
            WHEN avg_bal_3m <= 382.0                                  THEN  -3
            WHEN avg_bal_3m  < 772.9                                  THEN   2
            WHEN avg_bal_3m  < 2179.0                                 THEN   7
            WHEN avg_bal_3m  < 19560.0                                THEN  13
            ELSE                                                            20
        END +
        CASE
            WHEN merch_sum_amt_3m <=  2020                            THEN   2
            WHEN merch_sum_amt_3m  <  3676                            THEN   5
            WHEN merch_sum_amt_3m  <  6071                            THEN   8
            WHEN merch_sum_amt_3m  <  7366                            THEN  10
            WHEN merch_sum_amt_3m  < 10660                            THEN  16
            ELSE                                                            20
        END +
        CASE
            WHEN bet_cnt_trns_3m <= 0.5                               THEN   0
            WHEN bet_cnt_trns_3m  < 1.5                               THEN   5
            WHEN bet_cnt_trns_3m  < 8.5                               THEN  -8
            ELSE                                                           -20
        END
    ) INTO risk_score
    FROM (
        SELECT
            flz_sum_amt_6m, kplc_paybills_cnt_trns_6m,
            net_cashflow_6m, net_cnt_unq_sender_3m, net_banked_6m,
            all_received_money_sum_amt_3m, all_send_money_sum_amt_3m,
            p2p_received_money_cnt_unq_trns_1m,
            avg_bal_3m, merch_sum_amt_3m, bet_cnt_trns_3m,
            ROW_NUMBER() OVER (PARTITION BY mobile_number
                               ORDER BY date_created DESC) AS rn
        FROM  tbl_scoring_features
        WHERE mobile_number = ip_mobile_number
    ) AS latest_records
    WHERE rn = 1;

    SET risk_segment = CASE
        WHEN risk_score IS NULL  THEN 0
        WHEN risk_score <= 45    THEN 1
        WHEN risk_score <  65    THEN 2
        WHEN risk_score <  81    THEN 3
        WHEN risk_score < 105    THEN 4
        WHEN risk_score < 127    THEN 5
        WHEN risk_score < 141    THEN 6
        WHEN risk_score < 169    THEN 7
        ELSE                          8
    END;

    SET turnover_segment = CASE
        WHEN three_month_wavg IS NULL   THEN 0
        WHEN three_month_wavg <=   9841 THEN 1
        WHEN three_month_wavg <=  12561 THEN 2
        WHEN three_month_wavg <=  16027 THEN 3
        WHEN three_month_wavg <=  23895 THEN 4
        WHEN three_month_wavg <=  39179 THEN 5
        WHEN three_month_wavg <=  60463 THEN 6
        WHEN three_month_wavg <= 107556 THEN 7
        ELSE                                 8
    END;

    SET var_credit_limit = CASE
        WHEN age_days >= 90 AND risk_segment = 8 AND turnover_segment = 8 THEN 8000
        WHEN age_days >= 90 AND risk_segment = 8 AND turnover_segment = 7 THEN 7000
        WHEN age_days >= 90 AND risk_segment = 8 AND turnover_segment = 6 THEN 6000
        WHEN age_days >= 90 AND risk_segment = 8 AND turnover_segment = 5 THEN 5000

        WHEN age_days >= 90 AND risk_segment = 7 AND turnover_segment = 8 THEN 8000
        WHEN age_days >= 90 AND risk_segment = 7 AND turnover_segment = 7 THEN 6000
        WHEN age_days >= 90 AND risk_segment = 7 AND turnover_segment = 6 THEN 5000

        WHEN age_days >= 90 AND risk_segment = 6 AND turnover_segment = 8 THEN 6000
        WHEN age_days >= 90 AND risk_segment = 6 AND turnover_segment = 7 THEN 5000

        WHEN age_days >= 90 AND risk_segment = 5 AND turnover_segment = 8 THEN 5000

        ELSE 0
    END;

    -- Qualification must mirror the credit-limit matrix above: only combinations
    -- that receive a non-zero limit are marked qualified.
    SET model_category = CASE
        WHEN var_credit_limit > 0 THEN 'qualified'
        ELSE 'not_qualified'
    END;

    -- -------------------------------------------------------------------------
    -- Hard gate: customers with debt-to-income ratio > 50 % are rejected
    -- regardless of scorecard outcome.  Credit limit is forced to zero.
    -- -------------------------------------------------------------------------
    IF var_debt_to_income_ratio IS NOT NULL AND var_debt_to_income_ratio > 0.5000 THEN
        SET model_category   = 'not_qualified';
        SET var_credit_limit = 0;
    END IF;

    IF update_check = ip_mobile_number THEN

        INSERT INTO tbl_subscriber_profiles
            (mobile_number, last_updated,
             month1_turnover, month2_turnover, month3_turnover,
             age_days, three_month_wavg,
             risk_segment, turnover_segment, credit_limit, total_score, model_category,
             total_inflow, lender_inflow, debt_to_income_ratio,
             total_inflow_txn_count, lender_inflow_txn_count)
        VALUES
            (ip_mobile_number, NOW(),
             month1, month2, month3, age_days, three_month_wavg,
             risk_segment, turnover_segment, var_credit_limit, risk_score, model_category,
             var_total_inflow, var_lender_inflow, var_debt_to_income_ratio,
             var_total_inflow_txn_count, var_lender_inflow_txn_count);

        DELETE FROM customer_credit_limit
        WHERE  mobile_number = ip_mobile_number;

        INSERT INTO customer_credit_limit
            (mobile_number, credit_limit, profiling_date, profiling_category)
        VALUES
            (ip_mobile_number, var_credit_limit, NOW(), 'FTB2');

    ELSE

        INSERT INTO tbl_subscriber_profiles
            (mobile_number, last_updated,
             month1_turnover, month2_turnover, month3_turnover,
             age_days, three_month_wavg,
             risk_segment, turnover_segment, credit_limit, total_score, model_category,
             total_inflow, lender_inflow, debt_to_income_ratio,
             total_inflow_txn_count, lender_inflow_txn_count)
        VALUES
            (ip_mobile_number, NOW(),
             month1, month2, month3, age_days, three_month_wavg,
             risk_segment, turnover_segment, var_credit_limit, risk_score, model_category,
             var_total_inflow, var_lender_inflow, var_debt_to_income_ratio,
             var_total_inflow_txn_count, var_lender_inflow_txn_count);

        INSERT INTO customer_credit_limit
            (mobile_number, credit_limit, profiling_date, profiling_category)
        VALUES
            (ip_mobile_number, var_credit_limit, NOW(), 'FTB1');

    END IF;

    IF model_category = 'not_qualified' THEN
        CALL sp_populate_rejection_reasons(ip_mobile_number);
    END IF;

END$$

DELIMITER ;
