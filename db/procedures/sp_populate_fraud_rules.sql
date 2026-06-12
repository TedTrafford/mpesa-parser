-- DBeaver: highlight ONLY from "CREATE DEFINER" through "END;" (last line),
-- then Ctrl+Enter.  Do NOT include these comment lines.
-- Easiest:  python -m db.deploy_procedures

CREATE DEFINER=`production`@`%` PROCEDURE `Data_Science`.`sp_populate_fraud_rules`(
    IN p_mobile_number VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN

    SET collation_connection = 'utf8mb4_unicode_ci';

    -- Runtime path (fly_profiling) always passes one mobile. NULL batch mode scans
    -- the whole statements table and is not supported here.
    IF p_mobile_number IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_populate_fraud_rules requires p_mobile_number';
    END IF;

    IF p_mobile_number LIKE '0%' THEN
        SET p_mobile_number = CONCAT('254', SUBSTRING(p_mobile_number, 2));
    ELSEIF p_mobile_number LIKE '+%' THEN
        SET p_mobile_number = SUBSTRING(p_mobile_number, 2);
    END IF;

    -- Refresh: drop prior evaluation rows for the scope being recomputed.
    DELETE FROM tbl_fraud_rules
    WHERE mobile_number = p_mobile_number;

    INSERT INTO tbl_fraud_rules (
        mobile_number, evaluated_at, statement_span_days,
        flag_device_multi_id, flag_sim_phone_recency,
        flag_network_concentration, flag_circular_cash_movement,
        flag_shared_counterparties, flag_sudden_income_inflation,
        flag_borrowing_for_betting, flag_loan_cycling,
        flag_high_gambling_exposure, flag_active_loan_stacking,
        flag_excessive_borrowing_dependency, flag_high_volume_low_balance,
        total_score, decision, decision_action, triggered_rules, metrics
    )
    WITH
    scope AS (
        SELECT p_mobile_number AS mobile_number
    ),

    ref AS (
        SELECT
            mobile_number,
            MAX(transaction_date) AS ref_date,
            MIN(transaction_date) AS min_date
        FROM   tbl_raw_mpesa_statements
        WHERE  mobile_number = p_mobile_number
        GROUP  BY mobile_number
    ),

    txn AS (
        SELECT
            s.mobile_number,
            r.ref_date,
            r.min_date,
            s.receipt_no,
            s.amount,
            s.balance,
            TIMESTAMP(s.transaction_date, s.transaction_time) AS ts,
            s.transaction_date                              AS tdate,
            DATE_FORMAT(s.transaction_date, '%Y-%m')        AS ym,

            (s.transaction_date >= DATE_SUB(r.ref_date, INTERVAL 1 MONTH))  AS w1m,
            (s.transaction_date >= DATE_SUB(r.ref_date, INTERVAL 6 MONTH))  AS w6m,

            (s.amount < 0) AS is_debit,
            (s.amount > 0) AS is_credit,

            (s.transaction_type = 'SEND MONEY')     AS is_p2p_send,
            (s.transaction_type = 'RECEIVED MONEY') AS is_p2p_recv,

            CASE
                WHEN s.transaction_type IN ('SEND MONEY', 'RECEIVED MONEY')
                     AND s.details REGEXP '-[ \\t]*[0-9*]+[ \\t]+.+'
                THEN TRIM(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(s.details, '[ \\t]+', ' '),
                        '^.*-[ \\t]*[0-9*]+[ \\t]+',
                        ''
                    )
                )
            END AS p2p_counterparty,

            (
                s.details LIKE '%sportybet%'
                OR s.details LIKE '%sportpesa%'
                OR s.details LIKE '%betin%'
                OR s.details LIKE '%betway%'
                OR s.details LIKE '%1xbet%'
                OR s.details LIKE '%odibets%'
                OR s.details LIKE '%mozzartbet%'
                OR s.details LIKE '%betika%'
                OR s.details LIKE '%premierbet%'
                OR s.details LIKE '%melbet%'
                OR s.details LIKE '%shabiki%'
                OR s.details LIKE '%dafabet%'
                OR s.details LIKE '%elitebet%'
                OR s.details LIKE '%betlion%'
                OR s.details LIKE '%palmsbet%'
                OR s.details LIKE '%22bet%'
                OR s.details LIKE '%betpawa%'
                OR s.details LIKE '%bangbet%'
                OR s.details LIKE '%kwikbet%'
                OR s.details LIKE '%winbet%'
                OR (
                    s.transaction_type LIKE '%PAYBILL%'
                    AND INSTR(CONCAT(' ', LOWER(s.details), ' '), ' bet ') > 0
                )
            ) AS is_bet,

            (
                s.amount > 0
                AND (
                    s.details LIKE '%overdraft of credit party%'
                    OR s.details LIKE '%m-pesa overdraw%'
                    OR s.details LIKE '%od loan%'
                    OR s.details LIKE '%tala loan%'
                    OR s.details LIKE '%branch microfinance%'
                    OR s.details LIKE '%zenka digital%'
                    OR s.details LIKE '%timiza%'
                    OR s.details LIKE '%m-kopa%'
                    OR s.details LIKE '%h- fund%'
                    OR s.details LIKE '%h-fund%'
                    OR s.details LIKE '%hustler fund%'
                    OR s.details LIKE '%hfund savings%'
                    OR s.details LIKE '%term loan disbursement%'
                    OR s.details LIKE '%loop b2c%'
                    OR s.details LIKE '%loop business%'
                    OR s.details LIKE '%zash loan%'
                    OR s.details LIKE '%zillions credit%'
                    OR s.details LIKE '%chelete credit%'
                    OR s.details LIKE '%payablu credit%'
                    OR s.details LIKE '%chapeo capital%'
                    OR s.details LIKE '%creditarea capital%'
                    OR s.details LIKE '%loan plus digital%'
                    OR s.details LIKE '%simplepay capital%'
                    OR s.details LIKE '%ceres tech%'
                    OR s.details LIKE '%zamaradi capital%'
                    OR s.details LIKE '%fourth generation capital%'
                    OR s.details LIKE '%mular credit%'
                    OR s.details LIKE '%ajax credit%'
                    OR s.details LIKE '%mkulimapay credit%'
                    OR s.details LIKE '%risine credit%'
                    OR s.details LIKE '%pesa kuu credit%'
                    OR s.details LIKE '%goldstep capital%'
                    OR s.details LIKE '%azura credit%'
                    OR s.details LIKE '%flashpesa%'
                    OR s.details LIKE '%impala credit%'
                    OR s.details LIKE '%platinum credit%'
                    OR s.details LIKE '%bytech credit%'
                    OR s.details LIKE '%getcash capital%'
                    OR s.details LIKE '%milestone credit%'
                    OR s.details LIKE '%marble capital%'
                    OR s.details LIKE '%sure cred capital%'
                    OR s.details LIKE '%finberry capital%'
                    OR s.details LIKE '%inspire credit%'
                    OR s.details LIKE '%fast credit%'
                    OR s.details LIKE '%brisk credit%'
                    OR s.details LIKE '%okash%'
                    OR s.details LIKE '%mshwari%'
                    OR s.details LIKE '%fairmoney%'
                    OR s.details LIKE '%ipesa%'
                    OR s.details LIKE '%kopesh%'
                    OR s.details LIKE '%lendplus%'
                    OR s.details LIKE '%opesa%'
                )
            ) AS is_loan_disb,

            (
                s.amount < 0
                AND (
                    s.details LIKE '%Loan Repayment%'
                    OR s.details LIKE '%Loan Repay%'
                    OR s.details LIKE '%OD Loan Repayment%'
                    OR s.details LIKE '%M-PESA Overdraw%'
                    OR (
                        s.transaction_type LIKE '%PAYBILL%'
                        AND (
                            s.details LIKE '%Tala%'
                            OR s.details LIKE '%Branch%'
                            OR s.details LIKE '%OKash%'
                            OR s.details LIKE '%Zenka%'
                            OR s.details LIKE '%Timiza%'
                            OR s.details LIKE '%Hustler Fund%'
                            OR s.details LIKE '%Platinum Credit%'
                            OR s.details LIKE '%FairMoney%'
                            OR s.details LIKE '%LendPlus%'
                            OR s.details LIKE '%iPesa%'
                        )
                    )
                )
            ) AS is_loan_repay
        FROM   tbl_raw_mpesa_statements s
        INNER JOIN ref r ON r.mobile_number = s.mobile_number
        WHERE  s.transaction_date >= DATE_SUB(r.ref_date, INTERVAL 6 MONTH)
          AND  s.transaction_date <= r.ref_date
    ),

    -- Rule 1: Device Multi-ID Linkage (40)
    -- Uses device_id when present; falls back to phone_id from tbl_phone_id.
    device AS (
        SELECT
            p.mobile_number,
            MAX(CASE WHEN x.id_count > 3 THEN 1 ELSE 0 END) = 1 AS flag,
            MAX(x.id_count) AS max_id_count
        FROM tbl_phone_id p
        INNER JOIN scope sc ON sc.mobile_number = p.mobile_number
        INNER JOIN LATERAL (
            SELECT COUNT(DISTINCT p2.national_id) AS id_count
            FROM   tbl_phone_id p2
            WHERE  COALESCE(NULLIF(p2.device_id, ''), p2.phone_id)
                   = COALESCE(NULLIF(p.device_id, ''), p.phone_id)
              AND  COALESCE(NULLIF(p.device_id, ''), p.phone_id) <> ''
              AND  p2.created_at >= (
                       SELECT MAX(p3.created_at)
                       FROM   tbl_phone_id p3
                       WHERE  COALESCE(NULLIF(p3.device_id, ''), p3.phone_id)
                              = COALESCE(NULLIF(p.device_id, ''), p.phone_id)
                   ) - INTERVAL 90 DAY
        ) x ON TRUE
        WHERE COALESCE(NULLIF(p.device_id, ''), p.phone_id) <> ''
        GROUP BY p.mobile_number
    ),

    -- Rule 3: Network Concentration Analysis (30)
    cp_mon AS (
        SELECT
            mobile_number,
            p2p_counterparty AS cp,
            ym,
            COUNT(DISTINCT CASE WHEN is_p2p_send THEN receipt_no END) AS send_cnt,
            COUNT(DISTINCT CASE WHEN is_p2p_recv THEN receipt_no END) AS recv_cnt,
            COALESCE(SUM(CASE WHEN is_p2p_send THEN ABS(amount) END), 0) AS send_amt,
            COALESCE(SUM(CASE WHEN is_p2p_recv THEN amount END), 0)      AS recv_amt
        FROM   txn
        WHERE  w6m
          AND  (is_p2p_send OR is_p2p_recv)
          AND  p2p_counterparty IS NOT NULL
          AND  p2p_counterparty <> ''
        GROUP BY mobile_number, p2p_counterparty, ym
    ),
    network_conc AS (
        SELECT
            mobile_number,
            MAX(
                CASE
                    WHEN send_cnt > 0 AND recv_cnt > 0
                     AND (send_cnt + recv_cnt) > 5
                     AND ABS(send_amt - recv_amt)
                         / NULLIF(GREATEST(send_amt, recv_amt), 0) < 0.10
                    THEN 1 ELSE 0
                END
            ) = 1 AS flag
        FROM cp_mon
        GROUP BY mobile_number
    ),

    -- Rule 4: Circular Cash Movement (20)
    mon_dir AS (
        SELECT
            mobile_number,
            ym,
            COALESCE(SUM(CASE WHEN is_credit THEN amount END), 0)      AS recv,
            COALESCE(SUM(CASE WHEN is_debit  THEN ABS(amount) END), 0) AS sent
        FROM   txn
        WHERE  w6m
        GROUP BY mobile_number, ym
    ),
    circular AS (
        SELECT
            mobile_number,
            MAX(
                CASE
                    WHEN recv > 0 AND sent > 0
                     AND ABS(recv - sent) / GREATEST(recv, sent) <= 0.05
                    THEN 1 ELSE 0
                END
            ) = 1 AS flag
        FROM mon_dir
        GROUP BY mobile_number
    ),

    -- Rule 5: Shared Counterparties (20)
    -- Reuse p2p_counterparty from txn (single-subscriber window). Fanout is
    -- checked only for those senders; LIKE pre-filter avoids a full-table REGEXP
    -- pass that blocked procedure redeploy via metadata locks.
    target_senders AS (
        SELECT DISTINCT p2p_counterparty AS sender
        FROM   txn
        WHERE  is_p2p_recv
          AND  p2p_counterparty IS NOT NULL
          AND  p2p_counterparty <> ''
    ),
    sender_fanout AS (
        SELECT
            TRIM(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(s.details, '[ \\t]+', ' '),
                    '^.*-[ \\t]*[0-9*]+[ \\t]+',
                    ''
                )
            ) AS sender
        FROM tbl_raw_mpesa_statements s
        WHERE s.transaction_type = 'RECEIVED MONEY'
          AND s.transaction_date >= DATE_SUB(CURDATE(), INTERVAL 6 MONTH)
          AND s.details LIKE '%-%'
          AND s.details REGEXP '-[ \\t]*[0-9*]+[ \\t]+.+'
          AND EXISTS (
              SELECT 1
              FROM   target_senders ts
              WHERE  ts.sender <> ''
                AND  s.details LIKE CONCAT('%', ts.sender, '%')
          )
        GROUP BY sender
        HAVING COUNT(DISTINCT s.mobile_number) > 5
    ),
    shared AS (
        SELECT sc.mobile_number, 1 AS flag
        FROM   scope sc
        WHERE  EXISTS (
            SELECT 1
            FROM   target_senders ts
            INNER JOIN sender_fanout sf ON sf.sender = ts.sender
        )
    ),

    disb AS (
        SELECT mobile_number, receipt_no, tdate, ts, amount, ref_date
        FROM   txn
        WHERE  is_loan_disb
    ),
    loan_repay_dates AS (
        SELECT mobile_number, tdate AS repay_date
        FROM   txn
        WHERE  is_loan_repay
    ),

    -- Rule 7: Borrowing for Betting (20)
    borrow_bet AS (
        SELECT DISTINCT d.mobile_number, 1 AS flag
        FROM   disb d
        WHERE  EXISTS (
            SELECT 1
            FROM   txn b
            WHERE  b.mobile_number = d.mobile_number
              AND  b.is_bet AND b.is_debit
              AND  b.ts >  d.ts
              AND  b.ts <= d.ts + INTERVAL 48 HOUR
        )
    ),

    -- Rule 8: Loan Cycling Behavior (15)
    cycle AS (
        SELECT d.mobile_number, COUNT(*) AS cycle_cnt
        FROM   disb d
        WHERE  EXISTS (
                   SELECT 1
                   FROM   loan_repay_dates r
                   WHERE  r.mobile_number = d.mobile_number
                     AND  r.repay_date >  d.tdate
                     AND  r.repay_date <= d.tdate + INTERVAL 14 DAY
               )
          AND  EXISTS (
                   SELECT 1
                   FROM   disb d2
                   WHERE  d2.mobile_number = d.mobile_number
                     AND  d2.tdate >  d.tdate
                     AND  d2.tdate <= d.tdate + INTERVAL 30 DAY
               )
        GROUP BY d.mobile_number
    ),

    -- Rule 10: Active Loan Stacking (15)
    disb_flagged AS (
        SELECT
            d.mobile_number,
            d.receipt_no,
            (
                d.tdate <= DATE_SUB(d.ref_date, INTERVAL 3 MONTH)
                AND NOT EXISTS (
                    SELECT 1
                    FROM   loan_repay_dates r
                    WHERE  r.mobile_number = d.mobile_number
                      AND  r.repay_date >  d.tdate
                      AND  r.repay_date <= d.tdate + INTERVAL 3 MONTH
                )
            ) AS is_unrealised
        FROM disb d
    ),
    unrealised AS (
        SELECT
            mobile_number,
            COUNT(DISTINCT CASE WHEN is_unrealised THEN receipt_no END) AS cnt_unrealised
        FROM disb_flagged
        GROUP BY mobile_number
    ),

    agg AS (
        SELECT
            mobile_number,
            COALESCE(SUM(CASE WHEN is_credit AND w6m THEN amount END), 0)              AS credit_6m,
            COALESCE(SUM(CASE WHEN is_credit AND w1m THEN amount END), 0)              AS credit_1m,
            COALESCE(SUM(CASE WHEN is_loan_disb AND w6m THEN amount END), 0)           AS loan_disb_6m,
            COALESCE(SUM(CASE WHEN is_debit AND w1m THEN ABS(amount) END), 0)          AS debit_1m,
            COALESCE(SUM(CASE WHEN is_bet AND is_debit AND w1m THEN ABS(amount) END), 0) AS bet_1m,
            AVG(CASE WHEN w1m THEN balance END)                                        AS avg_balance_1m
        FROM   txn
        GROUP BY mobile_number
    ),

    evald AS (
        SELECT
            sc.mobile_number,
            DATEDIFF(r.ref_date, r.min_date) AS span_days,

            COALESCE(dev.flag, 0) AS f_device,
            (DATEDIFF(r.ref_date, r.min_date) < 90) AS f_sim,
            COALESCE(nc.flag, 0) AS f_network,
            COALESCE(cir.flag, 0) AS f_circular,
            COALESCE(sh.flag, 0) AS f_shared,
            COALESCE(a.credit_6m > 0 AND a.credit_1m * 6.0 / a.credit_6m > 3, 0) AS f_income,
            COALESCE(bb.flag, 0) AS f_borrow_bet,
            (COALESCE(cy.cycle_cnt, 0) > 3) AS f_cycle,
            COALESCE(a.debit_1m > 0 AND a.bet_1m / a.debit_1m > 0.30, 0) AS f_gambling,
            (COALESCE(ur.cnt_unrealised, 0) > 3) AS f_stacking,
            COALESCE(a.credit_6m > 0 AND COALESCE(a.loan_disb_6m, 0) / a.credit_6m > 0.50, 0) AS f_excessive,
            COALESCE(a.credit_1m > 0 AND COALESCE(a.avg_balance_1m, 0) < 0.05 * a.credit_1m, 0) AS f_lowbal,

            dev.max_id_count AS device_id_count,
            a.credit_6m, a.credit_1m, a.loan_disb_6m,
            a.debit_1m, a.bet_1m, a.avg_balance_1m,
            COALESCE(cy.cycle_cnt, 0) AS cycle_cnt,
            COALESCE(ur.cnt_unrealised, 0) AS cnt_unrealised
        FROM scope sc
        INNER JOIN ref r ON r.mobile_number = sc.mobile_number
        LEFT JOIN device dev ON dev.mobile_number = sc.mobile_number
        LEFT JOIN network_conc nc ON nc.mobile_number = sc.mobile_number
        LEFT JOIN circular cir ON cir.mobile_number = sc.mobile_number
        LEFT JOIN shared sh ON sh.mobile_number = sc.mobile_number
        LEFT JOIN borrow_bet bb ON bb.mobile_number = sc.mobile_number
        LEFT JOIN cycle cy ON cy.mobile_number = sc.mobile_number
        LEFT JOIN unrealised ur ON ur.mobile_number = sc.mobile_number
        LEFT JOIN agg a ON a.mobile_number = sc.mobile_number
    ),

    scored AS (
        SELECT
            e.*,
            (
                CASE WHEN f_device     THEN 40 ELSE 0 END
              + CASE WHEN f_sim        THEN 25 ELSE 0 END
              + CASE WHEN f_network    THEN 30 ELSE 0 END
              + CASE WHEN f_circular   THEN 20 ELSE 0 END
              + CASE WHEN f_shared     THEN 20 ELSE 0 END
              + CASE WHEN f_income     THEN 15 ELSE 0 END
              + CASE WHEN f_borrow_bet THEN 20 ELSE 0 END
              + CASE WHEN f_cycle      THEN 15 ELSE 0 END
              + CASE WHEN f_gambling   THEN 15 ELSE 0 END
              + CASE WHEN f_stacking   THEN 15 ELSE 0 END
              + CASE WHEN f_excessive  THEN 10 ELSE 0 END
              + CASE WHEN f_lowbal     THEN 10 ELSE 0 END
            ) AS total_score
        FROM evald e
    )
    SELECT
        mobile_number,
        NOW(),
        span_days,
        f_device, f_sim, f_network, f_circular, f_shared, f_income,
        f_borrow_bet, f_cycle, f_gambling, f_stacking, f_excessive, f_lowbal,
        total_score,
        CASE
            WHEN total_score >= 80 THEN 'Reject'
            WHEN total_score >= 60 THEN 'Manual Review'
            WHEN total_score >= 40 THEN 'Reduce Limit'
            ELSE                        'Approve'
        END,
        CASE
            WHEN total_score >= 80 THEN 'Critical fraud risk or confirmed gaming pattern. Automated hard rejection. Flag and blacklist National ID and unique Device Fingerprint.'
            WHEN total_score >= 60 THEN 'High risk profile. Hold disbursement pending secondary manual verification.'
            WHEN total_score >= 40 THEN 'Moderate risk. Truncate the calculated limit by 50-70% for the initial cycle.'
            ELSE                        'Low risk profile. Proceed with standard automated credit assignment and onboarding flow.'
        END,
        COALESCE(
            CONCAT_WS(' | ',
                CASE WHEN f_device     THEN 'Device Multi-ID Linkage (40)' END,
                CASE WHEN f_sim        THEN 'SIM/Phone Recency Check (25)' END,
                CASE WHEN f_network    THEN 'Network Concentration Analysis (30)' END,
                CASE WHEN f_circular   THEN 'Circular Cash Movement (20)' END,
                CASE WHEN f_shared     THEN 'Shared Counterparties (20)' END,
                CASE WHEN f_income     THEN 'Sudden Income Inflation (15)' END,
                CASE WHEN f_borrow_bet THEN 'Borrowing for Betting (20)' END,
                CASE WHEN f_cycle      THEN 'Loan Cycling Behavior (15)' END,
                CASE WHEN f_gambling   THEN 'High Gambling Exposure (15)' END,
                CASE WHEN f_stacking   THEN 'Active Loan Stacking (15)' END,
                CASE WHEN f_excessive  THEN 'Excessive Borrowing Dependency (10)' END,
                CASE WHEN f_lowbal     THEN 'High Volume, Low Balance (10)' END
            ),
            ''
        ),
        JSON_OBJECT(
            'statement_span_days',  span_days,
            'device_id_count',      device_id_count,
            'credit_6m',            ROUND(credit_6m, 2),
            'credit_1m',            ROUND(credit_1m, 2),
            'loan_disb_6m',         ROUND(loan_disb_6m, 2),
            'debit_1m',             ROUND(debit_1m, 2),
            'bet_1m',               ROUND(bet_1m, 2),
            'avg_balance_1m',       ROUND(COALESCE(avg_balance_1m, 0), 2),
            'income_inflation_ratio',
                CASE WHEN credit_6m > 0 THEN ROUND(credit_1m * 6.0 / credit_6m, 4) END,
            'gambling_exposure_ratio',
                CASE WHEN debit_1m > 0 THEN ROUND(bet_1m / debit_1m, 4) END,
            'borrowing_dependency_ratio',
                CASE WHEN credit_6m > 0 THEN ROUND(COALESCE(loan_disb_6m, 0) / credit_6m, 4) END,
            'loan_cycle_count',      cycle_cnt,
            'unrealised_loan_count', cnt_unrealised
        )
    FROM scored;

    -- Propagate hard rejections (decision = 'Reject') into tbl_rejection_reasons.
    CALL sp_populate_rejection_reasons(p_mobile_number);

    -- -------------------------------------------------------------------------
    -- Apply fraud-driven limit adjustments to rows written by fly_profiling.
    --   score >= 60 (Manual Review / Reject) -> limit 0
    --   score >= 40 (Reduce Limit)           -> limit halved when limit > 0
    -- -------------------------------------------------------------------------
    UPDATE customer_credit_limit ccl
    INNER JOIN tbl_fraud_rules fr ON fr.mobile_number = ccl.mobile_number
    SET
        ccl.credit_limit = CASE
            WHEN fr.total_score >= 60 THEN 0
            WHEN fr.total_score >= 40 AND ccl.credit_limit > 0
                THEN FLOOR(ccl.credit_limit / 2)
            ELSE ccl.credit_limit
        END,
        ccl.profiling_date = NOW(),
        ccl.profiling_category = CASE
            WHEN fr.total_score >= 80 THEN CONCAT(
                IF(ccl.profiling_category LIKE 'FTB2%', 'FTB2', 'FTB1'),
                '_FRAUD_reject'
            )
            WHEN fr.total_score >= 60 THEN CONCAT(
                IF(ccl.profiling_category LIKE 'FTB2%', 'FTB2', 'FTB1'),
                '_FRAUD_manual_review'
            )
            WHEN fr.total_score >= 40 AND ccl.credit_limit > 0 THEN CONCAT(
                IF(ccl.profiling_category LIKE 'FTB2%', 'FTB2', 'FTB1'),
                '_FRAUD_reduced'
            )
            ELSE ccl.profiling_category
        END
    WHERE fr.total_score >= 40
      AND (
          fr.total_score >= 60
          OR ccl.credit_limit > 0
      )
      AND (p_mobile_number IS NULL OR fr.mobile_number = p_mobile_number);

    UPDATE tbl_subscriber_profiles sp
    INNER JOIN (
        SELECT sp2.id, sp2.mobile_number
        FROM (
            SELECT id, mobile_number,
                   ROW_NUMBER() OVER (
                       PARTITION BY mobile_number
                       ORDER BY     last_updated DESC, id DESC
                   ) AS rn
            FROM tbl_subscriber_profiles
            WHERE (p_mobile_number IS NULL OR mobile_number = p_mobile_number)
        ) sp2
        WHERE sp2.rn = 1
    ) latest ON latest.id = sp.id
    INNER JOIN tbl_fraud_rules fr ON fr.mobile_number = sp.mobile_number
    SET
        sp.credit_limit = CASE
            WHEN fr.total_score >= 60 THEN 0
            WHEN fr.total_score >= 40 AND sp.credit_limit > 0
                THEN FLOOR(sp.credit_limit / 2)
            ELSE sp.credit_limit
        END,
        sp.model_category = CASE
            WHEN fr.total_score >= 80 THEN 'fraud_reject'
            WHEN fr.total_score >= 60 THEN 'Fraud_manual_review'
            WHEN fr.total_score >= 40 AND sp.credit_limit > 0 THEN 'Fraud_reduced'
            ELSE sp.model_category
        END
    WHERE fr.total_score >= 40
      AND (
          fr.total_score >= 60
          OR sp.credit_limit > 0
      )
      AND (p_mobile_number IS NULL OR fr.mobile_number = p_mobile_number);

END;
