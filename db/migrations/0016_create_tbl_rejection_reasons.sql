-- =============================================================================
-- Migration 0016: Create tbl_rejection_reasons + sp_populate_rejection_reasons
-- Description   : Explains why a subscriber was rated not_qualified, ordered
--                 from the most impactful gate to the least:
--
--                   Rank 1 � INSUFFICIENT_HISTORY  (age_days < 90; hard gate)
--                   Rank 1/2 � WEAK_SCORING_FEATURE (feature with highest score
--                              gap in the scorecard; highest potential impact)
--                   Rank 2/3 � LOW_TURNOVER          (three_month_wavg too low
--                              for the subscriber's risk_segment to qualify)
--                   Rank 2/3 � HIGH_CREDIT_RISK       (risk_segment ? 2; no
--                              achievable turnover can qualify the subscriber)
--
--                 The procedure is idempotent: it only processes rejected rows
--                 in tbl_subscriber_profiles that have no entry yet in
--                 tbl_rejection_reasons (matched on mobile_number).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Part 1: Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `tbl_rejection_reasons` (
    `id`             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,

    -- Subscriber identity
    `mobile_number`  VARCHAR(20)      NOT NULL DEFAULT '',

    -- FK to the specific tbl_subscriber_profiles row that was rejected
    `profile_id`     BIGINT UNSIGNED  NOT NULL,

    -- 1 = most impactful reason for this subscriber, 2 = next, etc.
    `reason_rank`    TINYINT UNSIGNED NOT NULL DEFAULT 1,

    -- Machine-readable code for downstream filtering / dashboards
    `reason_code`    VARCHAR(60)      NOT NULL,

    -- Human-readable explanation surfaced to the credit analyst
    `reason_detail`  TEXT             NOT NULL,

    -- Populated for WEAK_SCORING_FEATURE reasons only
    `feature_name`   VARCHAR(100)     DEFAULT NULL
                     COMMENT 'Scorecard feature that lost the most points',
    `feature_value`  DOUBLE           DEFAULT NULL
                     COMMENT 'Raw feature value at scoring time',
    `score_actual`   INT              DEFAULT NULL
                     COMMENT 'Points this feature actually contributed',
    `score_max`      INT              DEFAULT NULL
                     COMMENT 'Maximum points this feature could contribute',
    `score_gap`      INT              DEFAULT NULL
                     COMMENT 'score_max - score_actual (higher gap = more points lost)',

    -- Logistic sigmoid on total_score: 100 / (1 + exp(-(score - 100) / 35))
    -- Maps scorecard range (~-11 to 237) to a smooth repayment probability.
    -- Calibration reference points:
    --   score <= 45  (seg 1) -> ~17%  |  score ~81  (seg 3) -> ~39%
    --   score ~127   (seg 5) -> ~65%  |  score >= 169 (seg 8) -> ~88%
    `repayment_probability`
                     DECIMAL(5,2)     DEFAULT NULL
                     COMMENT 'Estimated probability of repayment (%) derived from total_score via logistic sigmoid',

    `date_created`   DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    INDEX `idx_rr_mobile_number` (`mobile_number`),
    INDEX `idx_rr_profile_id`    (`profile_id`),
    INDEX `idx_rr_reason_code`   (`reason_code`)

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Rejection reasons for not_qualified subscribers, ordered by impact';


-- ---------------------------------------------------------------------------
-- Part 2: Stored procedure
-- ---------------------------------------------------------------------------
-- NOTE: sp_populate_rejection_reasons is deployed at application startup via
-- db/procedures/sp_populate_rejection_reasons.sql (same mechanism as
-- fly_profiling).  It cannot be embedded here because the migration runner
-- (_split_statements in db/migrate.py) splits on ";" and cannot handle
-- stored-procedure bodies.  The DROP below ensures a clean re-deploy on the
-- next startup even if a partial version was left by a previous failed run.
-- ---------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS `sp_populate_rejection_reasons`;
