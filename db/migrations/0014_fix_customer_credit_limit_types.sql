-- =============================================================================
-- Migration 0014: Fix customer_credit_limit column types
-- Description   : Early deployments stored mobile_number as DECIMAL(18,4)
--                 and credit_limit as DECIMAL(18,4).  This caused phone
--                 numbers to display as 254,722,123,456.0000 and credit
--                 limits as 8,000.0000 (with thousands-separator commas) in
--                 database clients.
--
--                 MODIFY COLUMN is idempotent in MySQL: if the column is
--                 already the correct type this is a no-op.
-- =============================================================================

ALTER TABLE `customer_credit_limit`
    MODIFY COLUMN `mobile_number` VARCHAR(20) NOT NULL DEFAULT '';

ALTER TABLE `customer_credit_limit`
    MODIFY COLUMN `credit_limit` INT NOT NULL DEFAULT 0
