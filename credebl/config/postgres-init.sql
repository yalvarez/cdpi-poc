-- CDPI PoC — PostgreSQL initialization
-- Creates the keycloak schema inside the same database
-- Keycloak is configured to use schema=keycloak to share the DB instance

CREATE SCHEMA IF NOT EXISTS keycloak;
GRANT ALL ON SCHEMA keycloak TO credebl;
