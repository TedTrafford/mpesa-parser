-- =============================================================================
-- Migration 0009: Add profiling_status to tbl_file_processing_logs
-- Description   : Records the outcome of the fly_profiling() call made after
--                 each successful parse (e.g. 'OK', 'SKIPPED', 'FAILED: ...').
--
--                 Safe to re-run: error 1060 (column already exists) ? ignored.
-- =============================================================================

ALTER TABLE `tbl_file_processing_logs`
    ADD COLUMN `profiling_status` VARCHAR(255) NOT NULL DEFAULT ''
        AFTER `status`
