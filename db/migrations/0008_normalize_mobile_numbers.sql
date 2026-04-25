-- =============================================================================
-- Migration 0008: Normalize mobile numbers to international format
-- Description   : Converts legacy local-format numbers (0722xxx) stored in
--                 tbl_raw_mpesa_statements to international format (254722xxx)
--                 so they match the fly_profiling() JOIN keys.
--
--                 Idempotent: the WHERE clause ensures only un-normalised rows
--                 are touched.  Subsequent runs are no-ops.
-- =============================================================================

UPDATE `tbl_raw_mpesa_statements`
SET    `mobile_number` = CONCAT('254', SUBSTRING(`mobile_number`, 2))
WHERE  `mobile_number` LIKE '0%'
