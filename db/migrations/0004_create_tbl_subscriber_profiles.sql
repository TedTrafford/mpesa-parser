-- =============================================================================
-- Migration 0004: Create tbl_subscriber_profiles
-- Description   : Per-subscriber risk profile and credit limit output
--                 computed by fly_profiling().  One row is inserted per call.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_subscriber_profiles` (
    `id`               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `mobile_number`    VARCHAR(20)      NOT NULL DEFAULT '',
    `last_updated`     DATETIME         NOT NULL,
    `month1_turnover`  DOUBLE           DEFAULT NULL,
    `month2_turnover`  DOUBLE           DEFAULT NULL,
    `month3_turnover`  DOUBLE           DEFAULT NULL,
    `age_days`         DOUBLE           DEFAULT NULL,
    `three_month_wavg` DOUBLE           DEFAULT NULL,
    `risk_segment`     BIGINT           NOT NULL DEFAULT 0,
    `turnover_segment` DOUBLE           NOT NULL DEFAULT 0,
    `credit_limit`     INT              NOT NULL DEFAULT 0,
    `total_score`      DOUBLE           DEFAULT NULL,
    `model_category`   VARCHAR(50)      NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    INDEX `idx_sp_mobile_number` (`mobile_number`),
    INDEX `idx_sp_last_updated`  (`last_updated`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Per-subscriber risk profile and credit limit output from fly_profiling'
