-- =============================================================================
-- Migration 0023: Widen customer_credit_limit.profiling_category
--
-- Fraud-adjusted categories such as FTB1_FRAUD_manual_review exceed VARCHAR(20).
-- =============================================================================

ALTER TABLE `customer_credit_limit`
    MODIFY COLUMN `profiling_category` VARCHAR(50) NOT NULL DEFAULT '';
