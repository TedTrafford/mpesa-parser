-- =============================================================================
-- Migration 0012: Add supplied_phone_number to tbl_file_processing_logs
-- Description   : Stores the phone_number argument passed to parse_single.py,
--                 normalised to international format (254xxx).
--
--                 Safe to re-run: error 1060 (column already exists) ? ignored.
-- =============================================================================

ALTER TABLE `tbl_file_processing_logs`
    ADD COLUMN `supplied_phone_number` VARCHAR(20) NOT NULL DEFAULT ''
        AFTER `balance_check_pct`
