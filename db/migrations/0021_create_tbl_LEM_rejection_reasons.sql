-- =============================================================================
-- Migration 0021: Limit Enhancement Matrix (LEM) rejection reasons
--
-- Explains why a returning borrower was not granted a credit limit increase.
-- Populated by sp_populate_LEM_rejection_reasons (deployed from db/procedures/),
-- invoked at the end of sp_apply_credit_limit_enhancement.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_LEM_rejection_reasons` (
    `id`               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,

    `mobile_number`    VARCHAR(20)      NOT NULL DEFAULT '',
    `customer_id`      CHAR(36)         NOT NULL,
    `enhancement_id`   BIGINT UNSIGNED  DEFAULT NULL
                       COMMENT 'tbl_credit_limit_enhancements.id for this evaluation',

    `reason_rank`      TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `reason_code`      VARCHAR(60)      NOT NULL,
    `reason_detail`    TEXT             NOT NULL,

    `metric_name`      VARCHAR(100)     DEFAULT NULL,
    `metric_value`     DOUBLE           DEFAULT NULL,

    `date_created`     DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    INDEX `idx_lem_rr_mobile_number`  (`mobile_number`),
    INDEX `idx_lem_rr_customer_id`    (`customer_id`),
    INDEX `idx_lem_rr_enhancement_id` (`enhancement_id`),
    INDEX `idx_lem_rr_reason_code`      (`reason_code`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Rejection reasons for ineligible limit-enhancement evaluations';


DROP PROCEDURE IF EXISTS `sp_populate_LEM_rejection_reasons`;
