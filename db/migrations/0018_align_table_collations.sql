-- =============================================================================
-- Migration 0018: Align table collations to utf8mb4_unicode_ci
-- Description   : Production databases created on MySQL 8 default to
--                 utf8mb4_0900_ai_ci, while fly_profiling() declares its
--                 mobile_number parameter as utf8mb4_unicode_ci.  Comparing
--                 the two in WHERE mobile_number = ip_mobile_number raises:
--
--                   Error 1267: Illegal mix of collations
--                   (utf8mb4_unicode_ci,IMPLICIT) and (utf8mb4_0900_ai_ci,IMPLICIT)
--
--                 CONVERT TO rewrites every string column on each table so
--                 they match the collation used by migrations and procedures.
--                 Idempotent: no-op when a table is already utf8mb4_unicode_ci.
-- =============================================================================

ALTER TABLE `tbl_raw_mpesa_statements`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE `tbl_file_processing_logs`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE `tbl_scoring_features`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE `tbl_subscriber_profiles`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE `customer_credit_limit`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE `tbl_rejection_reasons`
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
