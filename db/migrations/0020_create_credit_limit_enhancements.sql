-- =============================================================================
-- Migration 0020: Credit limit enhancement audit table
--
-- Evaluation logic lives in db/procedures/sp_apply_credit_limit_enhancement.sql
-- (deployed at startup). LMS loan tables are read from the `aleza` database on
-- the same MySQL host; adjust the prefix in the procedure if your LMS schema
-- name differs.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_credit_limit_enhancements` (
    `id`                    BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `customer_id`           CHAR(36)         NOT NULL,
    `mobile_number`         VARCHAR(20)      NOT NULL,
    `evaluated_at`          DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,

    `current_limit`         INT              NOT NULL,
    `turnover_segment`      TINYINT UNSIGNED DEFAULT NULL,
    `three_month_wavg`      DOUBLE           DEFAULT NULL,
    `limit_band`            VARCHAR(20)      DEFAULT NULL,
    `enhancement_pct`       DECIMAL(5,2)     DEFAULT NULL,
    `enhanced_limit`        INT              DEFAULT NULL,

    `is_eligible`           TINYINT(1)       NOT NULL DEFAULT 0,
    `eligibility_detail`    TEXT             NOT NULL,
    `applied`               TINYINT(1)       NOT NULL DEFAULT 0,
    `applied_at`            DATETIME         DEFAULT NULL,

    `last_loan_days_late`   INT              DEFAULT NULL,
    `max_arrears_days_1y`   INT              DEFAULT NULL,
    `limit_age_days`        INT              DEFAULT NULL,
    `fraud_decision`        VARCHAR(20)      DEFAULT NULL,
    `debt_to_income_ratio`  DECIMAL(7,4)     DEFAULT NULL,

    PRIMARY KEY (`id`),
    INDEX `idx_cle_customer_id`   (`customer_id`),
    INDEX `idx_cle_mobile_number` (`mobile_number`),
    INDEX `idx_cle_evaluated_at`  (`evaluated_at`),
    INDEX `idx_cle_is_eligible`   (`is_eligible`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Credit limit enhancement evaluations (matrix + eligibility gates)';


DROP PROCEDURE IF EXISTS `sp_apply_credit_limit_enhancement`;
