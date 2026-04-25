-- =============================================================================
-- Migration 0005: Create customer_credit_limit
-- Description   : Lookup table of the most recent approved credit limit per
--                 subscriber.  fly_profiling() DELETEs + re-INSERTs the row
--                 on each call so the table always reflects the latest score.
--
--                 mobile_number is VARCHAR(20) -- consistent with every other
--                 table in the schema.  credit_limit is INT since limits are
--                 always whole-number amounts (0, 5000, 8000, etc.).
-- =============================================================================

CREATE TABLE IF NOT EXISTS `customer_credit_limit` (
    `id`                 BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `mobile_number`      VARCHAR(20)      NOT NULL DEFAULT '',
    `credit_limit`       INT              NOT NULL DEFAULT 0,
    `profiling_date`     DATETIME         NOT NULL,
    `profiling_category` VARCHAR(20)      NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    INDEX `idx_ccl_mobile_number` (`mobile_number`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Approved credit limits maintained by fly_profiling'
