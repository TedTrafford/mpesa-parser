-- =============================================================================
-- Migration 0006: Add record_id column to tbl_raw_mpesa_statements
-- Description   : Adds the caller-supplied unique identifier used by
--                 parse_single.py and an index to support lookups by it.
--
--                 Safe to re-run on existing databases: MySQL error 1060
--                 (duplicate column name) and 1061 (duplicate key name) are
--                 handled gracefully by the migration runner.
-- =============================================================================

ALTER TABLE `tbl_raw_mpesa_statements`
    ADD COLUMN `record_id` VARCHAR(255) NOT NULL DEFAULT ''
        COMMENT 'Caller-supplied unique identifier from parse_single.py'
        AFTER `id`;

ALTER TABLE `tbl_raw_mpesa_statements`
    ADD INDEX `idx_record_id` (`record_id`)
