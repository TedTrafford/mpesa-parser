-- ============================================================================
-- M-Pesa 207-Feature Engineering Query
-- Table   : tbl_raw_mpesa_statements  (Data_Science database)
-- Purpose : Credit-scoring feature extraction, grouped by mobile_number
-- Windows : Rolling 1M / 3M / 6M anchored on each customer's latest transaction_date
-- Features: 207 total across 17 groups
-- ============================================================================
--
-- Feature groups & counts
--   1.  ALL_SEND_MONEY       12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--   2.  ALL_RECEIVED_MONEY   12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--   3.  P2P_SEND_MONEY       15  (SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M)
--   4.  P2P_RECEIVED_MONEY   15  (SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M)
--   5.  AGENT_WITHDRAWAL     15  (SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M)
--   6.  ALL_PAYBILLS         12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--   7.  KPLC_PAYBILLS        12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--   8.  STK_WITHDRAWAL       12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--   9.  STK_DEPOSIT          12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  10.  AIRTIME              12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  11.  FLZ (Fuliza)         12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  12.  MERCH (Merchant)     12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  13.  P2P_FLZ               9  (AVG, MAX, CNT          × 1M/3M/6M)
--  14.  BET (Betting)        12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  15.  BANK_DEPOSIT         12  (SUM, AVG, MAX, CNT     × 1M/3M/6M)
--  16.  BALANCE               9  (AVG, MAX, MIN          × 1M/3M/6M)
--  17.  DERIVED              12  (NET_CASHFLOW, NET_CNT_SENDER,
--                                 NET_CNT_UNQ_SENDER, NET_BANKED × 1M/3M/6M)
-- ============================================================================

-- customer_ref: one row per mobile_number, holding their latest transaction date
-- as the rolling-window anchor (avoids data leakage from future rows)
WITH customer_ref AS (
    SELECT
        mobile_number,
        MAX(transaction_date) AS ref_date
    FROM tbl_raw_mpesa_statements
    GROUP BY mobile_number
),

flagged AS (
    SELECT
        t.mobile_number,
        t.transaction_date,
        cr.ref_date,
        ABS(t.amount)  AS abs_amt,
        t.amount,
        t.balance,

        -- ── 1 & 2: ALL SEND / ALL RECEIVE ────────────────────────────
        (t.amount < 0)  AS f_send,
        (t.amount > 0)  AS f_recv,

        -- ── 3: P2P SEND (excl. Fuliza-funded transfers) ──────────────
        -- Captures: SEND MONEY type, Customer Transfer to, Customer
        -- Payment to Small Business to — all without "Fuliza" in details
        (
            (
                t.transaction_type = 'SEND MONEY'
                OR t.details LIKE 'Customer Transfer to%'
                OR t.details LIKE 'Customer Payment to Small Business to%'
            )
            AND t.details NOT LIKE '%Fuliza%'
        ) AS f_p2p_send,

        -- ── 4: P2P RECEIVED MONEY ────────────────────────────────────
        -- Captures: RECEIVED MONEY type, Funds received from,
        -- Receive funds from (merchant float disbursements counted separately)
        (
            t.transaction_type = 'RECEIVED MONEY'
            OR t.details LIKE 'Funds received from%'
            OR t.details LIKE 'Receive funds from%'
        ) AS f_p2p_recv,

        -- ── 5: AGENT WITHDRAWAL ──────────────────────────────────────
        (t.transaction_type = 'AGENT WITHDRAWAL') AS f_agent_wd,

        -- ── 6: ALL PAYBILLS ──────────────────────────────────────────
        (t.transaction_type = 'LIPA NA M-PESA (PAYBILL)') AS f_paybill,

        -- ── 7: KPLC PAYBILLS ─────────────────────────────────────────
        -- Paybill 888880 = KPLC Prepaid, 888884 = KPLC Postpaid
        (
            t.transaction_type = 'LIPA NA M-PESA (PAYBILL)'
            AND (
                t.details LIKE '%KPLC%'
                OR t.details LIKE '%888880%'
                OR t.details LIKE '%888884%'
            )
        ) AS f_kplc,

        -- ── 8: STK WITHDRAWAL (Merchant/Till withdrawal into wallet) ──
        -- Money flowing from a merchant till into the customer's wallet
        (
            t.details LIKE '%Merchant Withdraw%'
            OR t.details LIKE '%Withdraw funds from%'
        ) AS f_stk_wd,

        -- ── 9: STK DEPOSIT (Cash-in at agent till) ───────────────────
        (
            t.details LIKE '%Deposit of Funds at Agent%'
            OR t.details LIKE '%Deposit%Agent Till%'
        ) AS f_stk_dep,

        -- ── 10: AIRTIME (all airtime incl. Fuliza-funded) ────────────
        (
            t.details LIKE '%Airtime Purchase%'
            OR t.details LIKE '%Recharge for Customer%'
        ) AS f_airtime,

        -- ── 11: FLZ — Fuliza loan repayments ─────────────────────────
        -- OD repayments to 232323 (M-Pesa Overdraw) and 3201003 (Fuliza II)
        (
            t.details LIKE '%OD Loan Repayment%'
            OR t.details LIKE '%Fuliza II Overdraw%'
        ) AS f_flz,

        -- ── 12: MERCH — Merchant payments ────────────────────────────
        (t.details LIKE '%Merchant Payment%') AS f_merch,

        -- ── 13: P2P_FLZ — P2P transfers funded by Fuliza credit ──────
        (
            t.details LIKE '%Customer Transfer Fuliza%'
            OR t.details LIKE '%Customer Send Money%Fuliza%'
            OR t.details LIKE '%Transfer Fuliza MPesa to%'
        ) AS f_p2p_flz,

        -- ── 14: BET — Betting / gambling paybills ────────────────────
        -- Keywords cover major Kenyan platforms; paybill numbers are fallback
        (
            t.details LIKE '%BETIKA%'
            OR t.details LIKE '%SportPesa%'
            OR t.details LIKE '%SPORTPESA%'
            OR t.details LIKE '%BETPAWA%'
            OR t.details LIKE '%BetWay%'
            OR t.details LIKE '%BETWAY%'
            OR t.details LIKE '%Odibets%'
            OR t.details LIKE '%ODIBETS%'
            OR t.details LIKE '%Mozzartbet%'
            OR t.details LIKE '%MOZZARTBET%'
            OR t.details LIKE '%1xbet%'
            OR t.details LIKE '%1XBET%'
            OR t.details LIKE '%BETIN%'
            OR (
                t.transaction_type = 'LIPA NA M-PESA (PAYBILL)'
                AND (
                    t.details LIKE '%290290%'    -- BETIKA
                    OR t.details LIKE '%400200%'  -- SportPesa
                    OR t.details LIKE '%5650400%' -- BetWay Kenya
                    OR t.details LIKE '%905084%'  -- BetPawa
                )
            )
        ) AS f_bet,

        -- ── 15: BANK_DEPOSIT — B2C disbursements from banks/MFIs ─────
        -- Positive Business Payments originating from regulated lenders /
        -- commercial banks (KCB, Equity, Cooperative, NCBA, Family, etc.)
        (
            t.details LIKE '%Business Payment from%'
            AND t.amount > 0
            AND (
                t.details LIKE '%Bank%'
                OR t.details LIKE '%KCB%'
                OR t.details LIKE '%TIMIZA%'
                OR t.details LIKE '%Pesa Pap%'
                OR t.details LIKE '%NCBA%'
                OR t.details LIKE '%Equity%'
                OR t.details LIKE '%Stanbic%'
                OR t.details LIKE '%Cooperative%'
                OR t.details LIKE '%Kingdom%'
                OR t.details LIKE '%Family%'
                OR t.details LIKE '%I&M%'
                OR t.details LIKE '%ABSA%'
                OR t.details LIKE '%DTB%'
                OR t.details LIKE '%Sidian%'
                OR t.details LIKE '%SIDIAN%'
                OR t.details LIKE '%Faulu%'
                OR t.details LIKE '%CFC%'
                OR t.details LIKE '%SBM%'
            )
        ) AS f_bank_dep,

        -- ── Counterparty keys for UNQ_CNT ────────────────────────────
        -- P2P Send: extract "... to - <masked_no> Name" tail
        CASE
            WHEN (
                t.transaction_type = 'SEND MONEY'
                OR t.details LIKE 'Customer Transfer to%'
                OR t.details LIKE 'Customer Payment to Small Business to%'
            ) AND t.details NOT LIKE '%Fuliza%'
            THEN TRIM(SUBSTRING_INDEX(t.details, ' to - ', -1))
            ELSE NULL
        END AS p2p_send_cpty,

        -- P2P Receive: extract "... from - <masked_no> Name" tail
        CASE
            WHEN t.transaction_type = 'RECEIVED MONEY'
                 OR t.details LIKE 'Funds received from%'
                 OR t.details LIKE 'Receive funds from%'
            THEN TRIM(SUBSTRING_INDEX(t.details, ' from - ', -1))
            ELSE NULL
        END AS p2p_recv_cpty,

        -- Agent Withdrawal: use full details as agent fingerprint
        CASE
            WHEN t.transaction_type = 'AGENT WITHDRAWAL'
            THEN t.details
            ELSE NULL
        END AS agent_cpty

    FROM tbl_raw_mpesa_statements t
    JOIN customer_ref cr ON t.mobile_number = cr.mobile_number
    WHERE t.transaction_date >= DATE_SUB(cr.ref_date, INTERVAL 6 MONTH)
)

SELECT
    mobile_number,

    -- =========================================================================
    -- 1. ALL_SEND_MONEY  │  SUM, AVG, MAX, CNT × 1M / 3M / 6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_send = 1 THEN 1     END)         AS ALL_SEND_MONEY_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_send = 1 THEN 1     END)         AS ALL_SEND_MONEY_CNT_3M,

    COALESCE(SUM(CASE WHEN f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_SUM_6M,
    COALESCE(AVG(CASE WHEN f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_AVG_6M,
    COALESCE(MAX(CASE WHEN f_send = 1 THEN abs_amt END), 0)   AS ALL_SEND_MONEY_MAX_6M,
           COUNT(CASE WHEN f_send = 1 THEN 1     END)         AS ALL_SEND_MONEY_CNT_6M,

    -- =========================================================================
    -- 2. ALL_RECEIVED_MONEY  │  SUM, AVG, MAX, CNT × 1M / 3M / 6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_recv = 1 THEN 1     END)         AS ALL_RECEIVED_MONEY_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_recv = 1 THEN 1     END)         AS ALL_RECEIVED_MONEY_CNT_3M,

    COALESCE(SUM(CASE WHEN f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_SUM_6M,
    COALESCE(AVG(CASE WHEN f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_AVG_6M,
    COALESCE(MAX(CASE WHEN f_recv = 1 THEN abs_amt END), 0)   AS ALL_RECEIVED_MONEY_MAX_6M,
           COUNT(CASE WHEN f_recv = 1 THEN 1     END)         AS ALL_RECEIVED_MONEY_CNT_6M,

    -- =========================================================================
    -- 3. P2P_SEND_MONEY  │  SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M  │  15 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN 1        END)                        AS P2P_SEND_MONEY_CNT_1M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN p2p_send_cpty END)                 AS P2P_SEND_MONEY_UNQ_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN abs_amt END), 0)                     AS P2P_SEND_MONEY_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN 1        END)                        AS P2P_SEND_MONEY_CNT_3M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN p2p_send_cpty END)                 AS P2P_SEND_MONEY_UNQ_CNT_3M,

    COALESCE(SUM(CASE WHEN f_p2p_send = 1 THEN abs_amt END), 0)   AS P2P_SEND_MONEY_SUM_6M,
    COALESCE(AVG(CASE WHEN f_p2p_send = 1 THEN abs_amt END), 0)   AS P2P_SEND_MONEY_AVG_6M,
    COALESCE(MAX(CASE WHEN f_p2p_send = 1 THEN abs_amt END), 0)   AS P2P_SEND_MONEY_MAX_6M,
           COUNT(CASE WHEN f_p2p_send = 1 THEN 1        END)      AS P2P_SEND_MONEY_CNT_6M,
    COUNT(DISTINCT CASE WHEN f_p2p_send = 1 THEN p2p_send_cpty END) AS P2P_SEND_MONEY_UNQ_CNT_6M,

    -- =========================================================================
    -- 4. P2P_RECEIVED_MONEY  │  SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M  │  15 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN 1        END)                        AS P2P_RECEIVED_MONEY_CNT_1M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN p2p_recv_cpty END)                 AS P2P_RECEIVED_MONEY_UNQ_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN abs_amt END), 0)                     AS P2P_RECEIVED_MONEY_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN 1        END)                        AS P2P_RECEIVED_MONEY_CNT_3M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN p2p_recv_cpty END)                 AS P2P_RECEIVED_MONEY_UNQ_CNT_3M,

    COALESCE(SUM(CASE WHEN f_p2p_recv = 1 THEN abs_amt END), 0)   AS P2P_RECEIVED_MONEY_SUM_6M,
    COALESCE(AVG(CASE WHEN f_p2p_recv = 1 THEN abs_amt END), 0)   AS P2P_RECEIVED_MONEY_AVG_6M,
    COALESCE(MAX(CASE WHEN f_p2p_recv = 1 THEN abs_amt END), 0)   AS P2P_RECEIVED_MONEY_MAX_6M,
           COUNT(CASE WHEN f_p2p_recv = 1 THEN 1        END)      AS P2P_RECEIVED_MONEY_CNT_6M,
    COUNT(DISTINCT CASE WHEN f_p2p_recv = 1 THEN p2p_recv_cpty END) AS P2P_RECEIVED_MONEY_UNQ_CNT_6M,

    -- =========================================================================
    -- 5. AGENT_WITHDRAWAL  │  SUM, AVG, MAX, CNT, UNQ_CNT × 1M/3M/6M  │  15 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_agent_wd = 1 THEN 1        END)                        AS AGENT_WITHDRAWAL_CNT_1M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_agent_wd = 1 THEN agent_cpty END)                    AS AGENT_WITHDRAWAL_UNQ_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_agent_wd = 1 THEN abs_amt END), 0)                     AS AGENT_WITHDRAWAL_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_agent_wd = 1 THEN 1        END)                        AS AGENT_WITHDRAWAL_CNT_3M,
    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_agent_wd = 1 THEN agent_cpty END)                    AS AGENT_WITHDRAWAL_UNQ_CNT_3M,

    COALESCE(SUM(CASE WHEN f_agent_wd = 1 THEN abs_amt END), 0)   AS AGENT_WITHDRAWAL_SUM_6M,
    COALESCE(AVG(CASE WHEN f_agent_wd = 1 THEN abs_amt END), 0)   AS AGENT_WITHDRAWAL_AVG_6M,
    COALESCE(MAX(CASE WHEN f_agent_wd = 1 THEN abs_amt END), 0)   AS AGENT_WITHDRAWAL_MAX_6M,
           COUNT(CASE WHEN f_agent_wd = 1 THEN 1        END)      AS AGENT_WITHDRAWAL_CNT_6M,
    COUNT(DISTINCT CASE WHEN f_agent_wd = 1 THEN agent_cpty END)  AS AGENT_WITHDRAWAL_UNQ_CNT_6M,

    -- =========================================================================
    -- 6. ALL_PAYBILLS  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_paybill = 1 THEN 1     END)         AS ALL_PAYBILLS_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_paybill = 1 THEN 1     END)         AS ALL_PAYBILLS_CNT_3M,

    COALESCE(SUM(CASE WHEN f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_SUM_6M,
    COALESCE(AVG(CASE WHEN f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_AVG_6M,
    COALESCE(MAX(CASE WHEN f_paybill = 1 THEN abs_amt END), 0)   AS ALL_PAYBILLS_MAX_6M,
           COUNT(CASE WHEN f_paybill = 1 THEN 1     END)         AS ALL_PAYBILLS_CNT_6M,

    -- =========================================================================
    -- 7. KPLC_PAYBILLS  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_kplc = 1 THEN 1     END)         AS KPLC_PAYBILLS_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_kplc = 1 THEN 1     END)         AS KPLC_PAYBILLS_CNT_3M,

    COALESCE(SUM(CASE WHEN f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_SUM_6M,
    COALESCE(AVG(CASE WHEN f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_AVG_6M,
    COALESCE(MAX(CASE WHEN f_kplc = 1 THEN abs_amt END), 0)   AS KPLC_PAYBILLS_MAX_6M,
           COUNT(CASE WHEN f_kplc = 1 THEN 1     END)         AS KPLC_PAYBILLS_CNT_6M,

    -- =========================================================================
    -- 8. STK_WITHDRAWAL  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- Merchant/till cash withdrawn into M-Pesa wallet (positive flows)
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_wd = 1 THEN 1     END)         AS STK_WITHDRAWAL_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_wd = 1 THEN 1     END)         AS STK_WITHDRAWAL_CNT_3M,

    COALESCE(SUM(CASE WHEN f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_SUM_6M,
    COALESCE(AVG(CASE WHEN f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_AVG_6M,
    COALESCE(MAX(CASE WHEN f_stk_wd = 1 THEN abs_amt END), 0)   AS STK_WITHDRAWAL_MAX_6M,
           COUNT(CASE WHEN f_stk_wd = 1 THEN 1     END)         AS STK_WITHDRAWAL_CNT_6M,

    -- =========================================================================
    -- 9. STK_DEPOSIT  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- Cash deposited at an M-Pesa agent till (positive flows)
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_stk_dep = 1 THEN 1     END)         AS STK_DEPOSIT_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_stk_dep = 1 THEN 1     END)         AS STK_DEPOSIT_CNT_3M,

    COALESCE(SUM(CASE WHEN f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_SUM_6M,
    COALESCE(AVG(CASE WHEN f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_AVG_6M,
    COALESCE(MAX(CASE WHEN f_stk_dep = 1 THEN abs_amt END), 0)   AS STK_DEPOSIT_MAX_6M,
           COUNT(CASE WHEN f_stk_dep = 1 THEN 1     END)         AS STK_DEPOSIT_CNT_6M,

    -- =========================================================================
    -- 10. AIRTIME  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_airtime = 1 THEN 1     END)         AS AIRTIME_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_airtime = 1 THEN 1     END)         AS AIRTIME_CNT_3M,

    COALESCE(SUM(CASE WHEN f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_SUM_6M,
    COALESCE(AVG(CASE WHEN f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_AVG_6M,
    COALESCE(MAX(CASE WHEN f_airtime = 1 THEN abs_amt END), 0)   AS AIRTIME_MAX_6M,
           COUNT(CASE WHEN f_airtime = 1 THEN 1     END)         AS AIRTIME_CNT_6M,

    -- =========================================================================
    -- 11. FLZ (Fuliza repayments)  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- OD Loan Repayment to 232323 (M-Pesa Overdraw) / 3201003 (Fuliza II)
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_flz = 1 THEN 1     END)         AS FLZ_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_flz = 1 THEN abs_amt END), 0)   AS FLZ_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_flz = 1 THEN 1     END)         AS FLZ_CNT_3M,

    COALESCE(SUM(CASE WHEN f_flz = 1 THEN abs_amt END), 0)   AS FLZ_SUM_6M,
    COALESCE(AVG(CASE WHEN f_flz = 1 THEN abs_amt END), 0)   AS FLZ_AVG_6M,
    COALESCE(MAX(CASE WHEN f_flz = 1 THEN abs_amt END), 0)   AS FLZ_MAX_6M,
           COUNT(CASE WHEN f_flz = 1 THEN 1     END)         AS FLZ_CNT_6M,

    -- =========================================================================
    -- 12. MERCH (Merchant payments)  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_merch = 1 THEN 1     END)         AS MERCH_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_merch = 1 THEN abs_amt END), 0)   AS MERCH_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_merch = 1 THEN 1     END)         AS MERCH_CNT_3M,

    COALESCE(SUM(CASE WHEN f_merch = 1 THEN abs_amt END), 0)   AS MERCH_SUM_6M,
    COALESCE(AVG(CASE WHEN f_merch = 1 THEN abs_amt END), 0)   AS MERCH_AVG_6M,
    COALESCE(MAX(CASE WHEN f_merch = 1 THEN abs_amt END), 0)   AS MERCH_MAX_6M,
           COUNT(CASE WHEN f_merch = 1 THEN 1     END)         AS MERCH_CNT_6M,

    -- =========================================================================
    -- 13. P2P_FLZ (P2P transfers funded by Fuliza credit)
    --     │  AVG, MAX, CNT × 1M/3M/6M  │  9 features
    -- =========================================================================
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_flz = 1 THEN 1     END)         AS P2P_FLZ_CNT_1M,

    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_flz = 1 THEN 1     END)         AS P2P_FLZ_CNT_3M,

    COALESCE(AVG(CASE WHEN f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_AVG_6M,
    COALESCE(MAX(CASE WHEN f_p2p_flz = 1 THEN abs_amt END), 0)   AS P2P_FLZ_MAX_6M,
           COUNT(CASE WHEN f_p2p_flz = 1 THEN 1     END)         AS P2P_FLZ_CNT_6M,

    -- =========================================================================
    -- 14. BET (Betting / gambling)  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bet = 1 THEN 1     END)         AS BET_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bet = 1 THEN abs_amt END), 0)   AS BET_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bet = 1 THEN 1     END)         AS BET_CNT_3M,

    COALESCE(SUM(CASE WHEN f_bet = 1 THEN abs_amt END), 0)   AS BET_SUM_6M,
    COALESCE(AVG(CASE WHEN f_bet = 1 THEN abs_amt END), 0)   AS BET_AVG_6M,
    COALESCE(MAX(CASE WHEN f_bet = 1 THEN abs_amt END), 0)   AS BET_MAX_6M,
           COUNT(CASE WHEN f_bet = 1 THEN 1     END)         AS BET_CNT_6M,

    -- =========================================================================
    -- 15. BANK_DEPOSIT (B2C from banks / MFIs)  │  SUM, AVG, MAX, CNT × 1M/3M/6M  │  12 features
    -- =========================================================================
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_SUM_1M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_MAX_1M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bank_dep = 1 THEN 1     END)         AS BANK_DEPOSIT_CNT_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_SUM_3M,
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_MAX_3M,
           COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bank_dep = 1 THEN 1     END)         AS BANK_DEPOSIT_CNT_3M,

    COALESCE(SUM(CASE WHEN f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_SUM_6M,
    COALESCE(AVG(CASE WHEN f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_AVG_6M,
    COALESCE(MAX(CASE WHEN f_bank_dep = 1 THEN abs_amt END), 0)   AS BANK_DEPOSIT_MAX_6M,
           COUNT(CASE WHEN f_bank_dep = 1 THEN 1     END)         AS BANK_DEPOSIT_CNT_6M,

    -- =========================================================================
    -- 16. BALANCE  │  AVG, MAX, MIN × 1M/3M/6M  │  9 features
    -- End-of-transaction balance snapshot per row
    -- =========================================================================
    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) THEN balance END), 0)   AS BALANCE_AVG_1M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) THEN balance END), 0)   AS BALANCE_MAX_1M,
    COALESCE(MIN(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) THEN balance END), 0)   AS BALANCE_MIN_1M,

    COALESCE(AVG(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) THEN balance END), 0)   AS BALANCE_AVG_3M,
    COALESCE(MAX(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) THEN balance END), 0)   AS BALANCE_MAX_3M,
    COALESCE(MIN(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) THEN balance END), 0)   AS BALANCE_MIN_3M,

    COALESCE(AVG(balance), 0)   AS BALANCE_AVG_6M,
    COALESCE(MAX(balance), 0)   AS BALANCE_MAX_6M,
    COALESCE(MIN(balance), 0)   AS BALANCE_MIN_6M,

    -- =========================================================================
    -- 17. DERIVED FEATURES  │  4 metrics × 1M/3M/6M  │  12 features
    --
    --   NET_CASHFLOW      = total received − total sent (signed, can be negative)
    --   NET_CNT_SENDER    = P2P received transactions − P2P sent transactions
    --   NET_CNT_UNQ_SENDER = unique P2P senders − unique P2P recipients
    --   NET_BANKED        = total bank B2C deposits received
    -- =========================================================================

    -- 1M
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_recv = 1 THEN abs_amt ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_send = 1 THEN abs_amt ELSE 0 END), 0)
                                                                                                     AS NET_CASHFLOW_1M,

    COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN 1 END)
      - COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN 1 END)
                                                                                                     AS NET_CNT_SENDER_1M,

    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_recv = 1 THEN p2p_recv_cpty END)
      - COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_p2p_send = 1 THEN p2p_send_cpty END)
                                                                                                     AS NET_CNT_UNQ_SENDER_1M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 1 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)
                                                                                                     AS NET_BANKED_1M,

    -- 3M
    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_recv = 1 THEN abs_amt ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_send = 1 THEN abs_amt ELSE 0 END), 0)
                                                                                                     AS NET_CASHFLOW_3M,

    COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN 1 END)
      - COUNT(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN 1 END)
                                                                                                     AS NET_CNT_SENDER_3M,

    COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_recv = 1 THEN p2p_recv_cpty END)
      - COUNT(DISTINCT CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_p2p_send = 1 THEN p2p_send_cpty END)
                                                                                                     AS NET_CNT_UNQ_SENDER_3M,

    COALESCE(SUM(CASE WHEN transaction_date >= DATE_SUB(ref_date, INTERVAL 3 MONTH) AND f_bank_dep = 1 THEN abs_amt END), 0)
                                                                                                     AS NET_BANKED_3M,

    -- 6M
    COALESCE(SUM(CASE WHEN f_recv = 1 THEN abs_amt ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN f_send = 1 THEN abs_amt ELSE 0 END), 0)
                                                                                                     AS NET_CASHFLOW_6M,

    COUNT(CASE WHEN f_p2p_recv = 1 THEN 1 END)
      - COUNT(CASE WHEN f_p2p_send = 1 THEN 1 END)
                                                                                                     AS NET_CNT_SENDER_6M,

    COUNT(DISTINCT CASE WHEN f_p2p_recv = 1 THEN p2p_recv_cpty END)
      - COUNT(DISTINCT CASE WHEN f_p2p_send = 1 THEN p2p_send_cpty END)
                                                                                                     AS NET_CNT_UNQ_SENDER_6M,

    COALESCE(SUM(CASE WHEN f_bank_dep = 1 THEN abs_amt END), 0)
                                                                                                     AS NET_BANKED_6M

FROM flagged
GROUP BY mobile_number;
