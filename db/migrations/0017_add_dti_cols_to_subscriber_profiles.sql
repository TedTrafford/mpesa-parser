-- =============================================================================
-- Migration 0017: Add debt-to-income ratio columns to tbl_subscriber_profiles
-- Description   : Stores the 6-month inflow totals and the resulting
--                 debt-to-income (DTI) ratio computed by fly_profiling().
--                 Customers whose DTI > 50 % are hard-gated to not_qualified.
--
--                 New columns:
--                   total_inflow            – KES sum of all positive txns (6m)
--                   lender_inflow           – KES sum of digital-lender inflows (6m)
--                   debt_to_income_ratio    – lender_inflow / total_inflow (4 d.p.)
--                   total_inflow_txn_count  – count of all positive txns (6m)
--                   lender_inflow_txn_count – count of digital-lender txns (6m)
--
--                 Safe to re-run: error 1060 (column already exists) -> ignored.
-- =============================================================================

ALTER TABLE `tbl_subscriber_profiles`
    ADD COLUMN `total_inflow`              DOUBLE          DEFAULT NULL
        COMMENT 'KES sum of all positive M-PESA transactions in last 6 months'
        AFTER `model_category`,
    ADD COLUMN `lender_inflow`             DOUBLE          DEFAULT NULL
        COMMENT 'KES sum of inflows matched to known digital lenders in last 6 months'
        AFTER `total_inflow`,
    ADD COLUMN `debt_to_income_ratio`      DECIMAL(7, 4)   DEFAULT NULL
        COMMENT 'lender_inflow / total_inflow; NULL when total_inflow = 0'
        AFTER `lender_inflow`,
    ADD COLUMN `total_inflow_txn_count`    BIGINT          DEFAULT NULL
        COMMENT 'Count of all positive M-PESA transactions in last 6 months'
        AFTER `debt_to_income_ratio`,
    ADD COLUMN `lender_inflow_txn_count`   BIGINT          DEFAULT NULL
        COMMENT 'Count of digital-lender inflow transactions in last 6 months'
        AFTER `total_inflow_txn_count`
