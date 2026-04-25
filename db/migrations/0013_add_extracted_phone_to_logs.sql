-- =============================================================================
-- Migration 0013: Add extracted_phone_number to tbl_file_processing_logs
-- Description   : Stores the mobile number extracted from the PDF statement,
--                 normalised to international format (254xxx).
--
--                 Safe to re-run: error 1060 (column already exists) ? ignored.
-- =============================================================================

ALTER TABLE `tbl_file_processing_logs`
    ADD COLUMN `extracted_phone_number` VARCHAR(20) NOT NULL DEFAULT ''
        AFTER `supplied_phone_number`
