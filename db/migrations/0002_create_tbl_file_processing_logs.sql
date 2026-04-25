-- =============================================================================
-- Migration 0002: Create tbl_file_processing_logs
-- Description   : Audit log for every PDF parsing job — tracks outcome,
--                 row counts, profiling status, and phone validation.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_file_processing_logs` (
    `id`                     BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `filename`               VARCHAR(255)     NOT NULL DEFAULT '',
    `md5`                    VARCHAR(32)      NOT NULL DEFAULT '',
    `manifest_hash`          VARCHAR(32)      NOT NULL DEFAULT '',
    `source`                 VARCHAR(100)     NOT NULL DEFAULT '',
    `source_path`            TEXT             NOT NULL,
    `destination`            TEXT             NOT NULL,
    `record_id`              VARCHAR(255)     NOT NULL DEFAULT '',
    `rows_inserted`          INT              NOT NULL DEFAULT 0,
    `rows_skipped`           INT              NOT NULL DEFAULT 0,
    `start_time`             DATETIME         NOT NULL,
    `end_time`               DATETIME         NOT NULL,
    `duration_seconds`       DECIMAL(10, 2)   NOT NULL DEFAULT 0.00,
    `status`                 VARCHAR(20)      NOT NULL DEFAULT '',
    `profiling_status`       VARCHAR(255)     NOT NULL DEFAULT '',
    `phone_match`            VARCHAR(10)      NOT NULL DEFAULT '',
    `balance_check_pct`      DECIMAL(5, 2)    DEFAULT NULL,
    `supplied_phone_number`  VARCHAR(20)      NOT NULL DEFAULT '',
    `extracted_phone_number` VARCHAR(20)      NOT NULL DEFAULT '',
    `error`                  TEXT             NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_log_record_id`  (`record_id`),
    INDEX `idx_log_status`     (`status`),
    INDEX `idx_log_filename`   (`filename`),
    INDEX `idx_log_start_time` (`start_time`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='File processing audit log for M-PESA PDF parsing jobs'
