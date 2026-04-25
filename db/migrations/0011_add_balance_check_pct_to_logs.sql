-- =============================================================================
-- Migration 0011: Add balance_check_pct to tbl_file_processing_logs
-- Description   : Stores the percentage of consecutive transaction pairs
--                 (ordered by date/time) where balance[i] == balance[i-1]
--                 + amount[i].  NULL when the parse failed or the file had
--                 fewer than 2 transactions.
--
--                 Safe to re-run: error 1060 (column already exists) ? ignored.
-- =============================================================================

ALTER TABLE `tbl_file_processing_logs`
    ADD COLUMN `balance_check_pct` DECIMAL(5, 2) DEFAULT NULL
        AFTER `phone_match`
