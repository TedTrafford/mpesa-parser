-- =============================================================================
-- Migration 0025: Normalize profiling_category on enhancement evaluations
--
-- Dry runs (applied = 0): evaluation_enhanced / evaluation_not_enhanced
-- Apply without increase: not_enhanced
-- Applied increases: ENHANCED_N (unchanged)
-- =============================================================================

ALTER TABLE `tbl_credit_limit_enhancements`
    MODIFY COLUMN `profiling_category` VARCHAR(50) DEFAULT NULL;

UPDATE `tbl_credit_limit_enhancements`
SET    `profiling_category` = CASE
           WHEN `is_eligible` = 1
            AND `proposed_limit` IS NOT NULL
            AND `proposed_limit` > `current_limit`
           THEN 'evaluation_enhanced'
           ELSE 'evaluation_not_enhanced'
       END
WHERE  `applied` = 0;

UPDATE `tbl_credit_limit_enhancements`
SET    `profiling_category` = 'not_enhanced'
WHERE  `applied` = 1
  AND  `is_eligible` = 0;

UPDATE `tbl_credit_limit_enhancements`
SET    `profiling_category` = 'evaluation_not_enhanced'
WHERE  `profiling_category` IS NULL;
