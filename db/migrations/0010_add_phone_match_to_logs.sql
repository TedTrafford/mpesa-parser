-- =============================================================================
-- Migration 0010: Add phone_match to tbl_file_processing_logs
-- Description   : Stores the result of validating the caller-supplied phone
--                 number against the mobile number extracted from the PDF:
--                 'MATCH', 'NO_MATCH', or 'N/A'.
--
--                 Safe to re-run: error 1060 (column already exists) ? ignored.
-- =============================================================================

ALTER TABLE `tbl_file_processing_logs`
    ADD COLUMN `phone_match` VARCHAR(10) NOT NULL DEFAULT ''
        AFTER `profiling_status`
