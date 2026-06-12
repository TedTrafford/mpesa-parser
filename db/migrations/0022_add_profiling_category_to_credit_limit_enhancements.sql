-- =============================================================================
-- Migration 0022: Add profiling_category to tbl_credit_limit_enhancements
--
-- Stores revisioned enhancement labels (ENHANCED_1, ENHANCED_2, ...) per
-- evaluation run. History is retained; consumers pick the latest row by
-- evaluated_at / id.
-- =============================================================================

ALTER TABLE `tbl_credit_limit_enhancements`
    ADD COLUMN `profiling_category` VARCHAR(20) DEFAULT NULL
        AFTER `enhanced_limit`;
