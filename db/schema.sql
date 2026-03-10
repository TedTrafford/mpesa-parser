-- =============================================================================
-- Schema: tbl_raw_mpesa_statements
-- Database: Data_Science (MySQL)
-- Description: Raw M-PESA statement transactions parsed from PDF files.
--              receipt_no is globally unique (issued by Safaricom), so it
--              acts as the natural dedup key.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_raw_mpesa_statements` (
    `id`                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,

    -- Customer / account header (repeated per transaction row)
    `customer_name`     VARCHAR(255)        NOT NULL DEFAULT '',
    `mobile_number`     VARCHAR(20)         NOT NULL DEFAULT '',
    `email_address`     VARCHAR(255)        NOT NULL DEFAULT '',
    `statement_period`  VARCHAR(100)        NOT NULL DEFAULT '',
    `request_date`      VARCHAR(50)         NOT NULL DEFAULT '',

    -- Transaction fields
    `transaction_date`  DATE                NOT NULL,
    `transaction_time`  TIME                NOT NULL,
    `receipt_no`        VARCHAR(20)         NOT NULL,
    `transaction_type`  VARCHAR(100)        NOT NULL DEFAULT '',
    `details`           TEXT                NOT NULL,
    `amount`            DECIMAL(15, 2)      NOT NULL,
    `balance`           DECIMAL(15, 2)      NOT NULL,

    -- JSONB-style metadata column
    -- {
    --   "manifest_hash"    : "<md5 of filename+content>",
    --   "pin"              : "<pdf filename stem>",
    --   "record_uuid"      : "<uuid4>",
    --   "output_file_path" : "<absolute path to output CSV>"
    -- }
    `metadata`          JSON                NOT NULL,

    PRIMARY KEY (`id`),
    UNIQUE KEY  `uq_receipt_no` (`receipt_no`),
    INDEX       `idx_mobile_number`  (`mobile_number`),
    INDEX       `idx_transaction_date` (`transaction_date`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Raw M-PESA statement transactions parsed from PDF files';
