-- =============================================================================
-- Migration 0007: Replace single-column unique key on receipt_no
-- Description   : M-PESA service charges share a receipt_no with their
--                 parent transaction but carry a different amount, so they
--                 are NOT duplicates.  The old uq_receipt_no key wrongly
--                 blocked them.  The new composite key (receipt_no, amount)
--                 allows service charges while still deduplicating true
--                 duplicate submissions.
--
--                 Safe to re-run on existing databases:
--                   - DROP INDEX: error 1091 (doesn't exist) ? ignored
--                   - ADD UNIQUE KEY: error 1061 (already exists) ? ignored
-- =============================================================================

ALTER TABLE `tbl_raw_mpesa_statements`
    DROP INDEX `uq_receipt_no`;

ALTER TABLE `tbl_raw_mpesa_statements`
    ADD UNIQUE KEY `uq_receipt_amount` (`receipt_no`, `amount`)
