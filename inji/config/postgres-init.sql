-- CDPI PoC — INJI PostgreSQL initialization
-- Creates separate schemas for each INJI service within the same DB instance

-- eSignet schema
CREATE SCHEMA IF NOT EXISTS esignet;
CREATE USER esignet_user WITH PASSWORD 'CHANGE_ME_ESIGNET';
GRANT ALL ON SCHEMA esignet TO esignet_user;
GRANT ALL ON SCHEMA esignet TO inji;

-- Certify schema
CREATE SCHEMA IF NOT EXISTS certify;
CREATE USER certify_user WITH PASSWORD 'CHANGE_ME_CERTIFY';
GRANT ALL ON SCHEMA certify TO certify_user;
GRANT ALL ON SCHEMA certify TO inji;

-- Mimoto schema
CREATE SCHEMA IF NOT EXISTS mimoto;
CREATE USER mimoto_user WITH PASSWORD 'CHANGE_ME_MIMOTO';
GRANT ALL ON SCHEMA mimoto TO mimoto_user;
GRANT ALL ON SCHEMA mimoto TO inji;

-- NOTE: The passwords above are placeholders.
-- The actual passwords are set via environment variables in the service configs.
-- This script just creates the schemas — Spring Boot auto-creates the tables on first run.
