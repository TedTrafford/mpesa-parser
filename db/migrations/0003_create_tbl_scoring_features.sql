-- =============================================================================
-- Migration 0003: Create tbl_scoring_features
-- Description   : Holds the 18 engineered features derived from
--                 tbl_raw_mpesa_statements that feed the credit scorecard.
--                 One row is inserted per fly_profiling() call.
-- =============================================================================

CREATE TABLE IF NOT EXISTS `tbl_scoring_features` (
    `id`                                 BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `mobile_number`                      VARCHAR(20)      NOT NULL DEFAULT '',
    `date_created`                       DATETIME         NOT NULL,
    `flz_sum_amt_6m`                     DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `kplc_paybills_cnt_trns_6m`          BIGINT           NOT NULL DEFAULT 0,
    `all_received_money_sum_amt_6m`      DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `all_send_money_sum_amt_6m`          DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `p2p_send_money_cnt_unq_trns_3m`     BIGINT           NOT NULL DEFAULT 0,
    `p2p_received_money_cnt_unq_trns_3m` BIGINT           NOT NULL DEFAULT 0,
    `bank_deposit_sum_amt_6m`            DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `p2p_received_money_sum_amt_6m`      DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `all_received_money_sum_amt_3m`      DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `all_send_money_sum_amt_3m`          DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `p2p_received_money_cnt_unq_trns_1m` BIGINT           NOT NULL DEFAULT 0,
    `avg_bal_3m`                         DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `merch_sum_amt_3m`                   DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `bet_cnt_trns_3m`                    BIGINT           NOT NULL DEFAULT 0,
    `net_cashflow_6m`                    DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    `net_cnt_unq_sender_3m`              BIGINT           NOT NULL DEFAULT 0,
    `net_banked_6m`                      DECIMAL(15,2)    NOT NULL DEFAULT 0.00,
    PRIMARY KEY (`id`),
    INDEX `idx_sf_mobile_number` (`mobile_number`),
    INDEX `idx_sf_date_created`  (`date_created`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Engineered features computed by fly_profiling for the scorecard'
