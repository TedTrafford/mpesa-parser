-- =============================================================================
-- Migration 0015: Fix customer_credit_limit column types and clean data
-- Description   : Ensures mobile_number is VARCHAR(20) and credit_limit is
--                 INT, then cleans any leftover DECIMAL artefacts in existing
--                 rows.
--
--                 Why this is needed
--                 ------------------
--                 The original schema stored both columns as DECIMAL(18,4).
--                 This caused large numbers to display with thousands-separator
--                 commas in database clients (e.g. 254,722,123,456.0000).
--
--                 Migration 0014 added the MODIFY COLUMN statements but may
--                 have been skipped on existing databases that used --baseline
--                 to register their current state without running SQL.
--
--                 When DECIMAL(18,4) -> VARCHAR(20), MySQL converts the stored
--                 value to a string including the decimal part, so
--                 254722123456.0000 becomes '254722123456.0000'.  The UPDATE
--                 below strips that suffix from any rows where it is present.
--
--                 All three statements are idempotent -- safe to run on any
--                 database regardless of its current state.
-- =============================================================================

-- Step 1: Fix mobile_number column type.
-- MODIFY COLUMN is a no-op when the column is already VARCHAR(20).
ALTER TABLE `customer_credit_limit`
    MODIFY COLUMN `mobile_number` VARCHAR(20)
        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
        NOT NULL DEFAULT '';

-- Step 2: Strip the '.0000' decimal artefact from any rows that were
-- converted from DECIMAL storage (e.g. '254722123456.0000' -> '254722123456').
-- Rows already in clean format are unaffected (WHERE clause matches nothing).
UPDATE `customer_credit_limit`
    SET `mobile_number` = SUBSTRING_INDEX(`mobile_number`, '.', 1)
    WHERE `mobile_number` LIKE '%.%';

-- Step 3: Fix credit_limit column type.
-- MODIFY COLUMN is a no-op when the column is already INT.
ALTER TABLE `customer_credit_limit`
    MODIFY COLUMN `credit_limit` INT NOT NULL DEFAULT 0
