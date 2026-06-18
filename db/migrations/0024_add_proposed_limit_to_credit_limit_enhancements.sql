-- =============================================================================
-- Migration 0024: Add proposed_limit to tbl_credit_limit_enhancements
--
-- proposed_limit  = matrix-calculated target (e.g. 8,000)
-- enhanced_limit  = actual limit after this evaluation (unchanged if ineligible)
-- =============================================================================

ALTER TABLE `tbl_credit_limit_enhancements`
    ADD COLUMN `proposed_limit` INT DEFAULT NULL
        AFTER `enhancement_pct`;

-- Historical rows stored the matrix target in enhanced_limit.
UPDATE `tbl_credit_limit_enhancements`
SET    `proposed_limit` = `enhanced_limit`
WHERE  `proposed_limit` IS NULL
  AND  `enhanced_limit` IS NOT NULL;

UPDATE `tbl_credit_limit_enhancements`
SET    `enhanced_limit` = `current_limit`
WHERE  `is_eligible` = 0;
