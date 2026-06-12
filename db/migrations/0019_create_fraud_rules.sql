-- =============================================================================
-- Migration 0019: Fraud / gaming risk framework
--
-- Creates tbl_phone_id (device / identity registry) and tbl_fraud_rules
-- (per-customer fraud evaluation result). The evaluation logic lives in
-- db/procedures/sp_populate_fraud_rules.sql (deployed at startup).
--
-- Decision thresholds (sum of triggered rule weights):
--     0 - 39   Approve
--    40 - 59   Reduce Limit
--    60 - 79   Manual Review
--    80+       Reject  -> FRAUD_CRITICAL reason; limit 0; fraud_reject
--    60-79     Manual Review -> limit 0; Fraud_manual_review
--    40-59     Reduce Limit  -> limit halved when > 0; Fraud_reduced
-- Limit adjustments are applied in sp_populate_fraud_rules after fly_profiling.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_phone_id` (
    `id`                BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `mobile_number`     VARCHAR(20)      NOT NULL,
    `phone_id`          VARCHAR(64)      NOT NULL DEFAULT ''
        COMMENT 'Logical phone / account identifier',
    `national_id`       VARCHAR(32)      NOT NULL DEFAULT ''
        COMMENT 'National ID document number',
    `device_id`         VARCHAR(128)     NOT NULL DEFAULT ''
        COMMENT 'Device fingerprint',
    `sim_serial`        VARCHAR(32)      NOT NULL DEFAULT ''
        COMMENT 'ICCID / SIM serial',
    `line_activated_at` DATETIME         DEFAULT NULL
        COMMENT 'SIM / line activation date',
    `created_at`        DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP
        COMMENT 'Linkage capture date',
    PRIMARY KEY (`id`),
    INDEX `idx_phone_id_mobile_number` (`mobile_number`),
    INDEX `idx_phone_id_device_id`     (`device_id`),
    INDEX `idx_phone_id_national_id`   (`national_id`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Identity / device fingerprint registry for fraud linkage rules';


CREATE TABLE IF NOT EXISTS `tbl_fraud_rules` (
    `id`                                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `mobile_number`                       VARCHAR(20)     NOT NULL,
    `evaluated_at`                        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `statement_span_days`                 INT             DEFAULT NULL,

    -- Identity & Device
    `flag_device_multi_id`                TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_sim_phone_recency`              TINYINT(1)      NOT NULL DEFAULT 0,
    -- Statement & Velocity
    `flag_network_concentration`          TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_circular_cash_movement`         TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_shared_counterparties`          TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_sudden_income_inflation`        TINYINT(1)      NOT NULL DEFAULT 0,
    -- Credit Distress
    `flag_borrowing_for_betting`          TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_loan_cycling`                   TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_high_gambling_exposure`         TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_active_loan_stacking`           TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_excessive_borrowing_dependency` TINYINT(1)      NOT NULL DEFAULT 0,
    `flag_high_volume_low_balance`        TINYINT(1)      NOT NULL DEFAULT 0,

    `total_score`                         INT             NOT NULL DEFAULT 0,
    `decision`                            VARCHAR(20)     NOT NULL DEFAULT 'Approve',
    `decision_action`                     TEXT            NOT NULL,
    `triggered_rules`                     TEXT            NOT NULL,
    `metrics`                             JSON            NOT NULL,

    PRIMARY KEY (`id`),
    INDEX `idx_fraud_mobile_number` (`mobile_number`),
    INDEX `idx_fraud_decision`      (`decision`),
    INDEX `idx_fraud_evaluated_at`  (`evaluated_at`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Per-customer fraud evaluation result (latest state per run)';


DROP PROCEDURE IF EXISTS `sp_populate_fraud_rules`;
