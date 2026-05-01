-- CDPI PoC — INJI PostgreSQL initialization
-- Creates separate schemas for each INJI service within the same DB instance

-- NOTE on eSignet search_path:
-- eSignet Hibernate JPA queries for client_detail omit the schema prefix.
-- The fix is in esignet/application.properties via HikariCP connection-init-sql:
--   spring.datasource.hikari.connection-init-sql=SET search_path TO esignet
-- This scopes the search_path to eSignet's connection pool only, without
-- affecting the other services (mock-identity-system, certify, mimoto) that
-- share the same 'inji' DB user.
-- DO NOT use ALTER ROLE inji SET search_path here — it breaks all other services.

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

-- Mock Identity System schema (required by esignet-mock-plugin)
CREATE SCHEMA IF NOT EXISTS mockidentitysystem;
CREATE USER mockid_user WITH PASSWORD 'CHANGE_ME_MOCKID';
GRANT ALL ON SCHEMA mockidentitysystem TO mockid_user;
GRANT ALL ON SCHEMA mockidentitysystem TO inji;

-- Keymanager tables for mock-identity-system
-- (kernel-keymanager JAR has hibernate.hbm2ddl.auto=none so we must create these manually)
SET search_path TO mockidentitysystem;

CREATE TABLE IF NOT EXISTS key_alias (
    id                character varying(36)       NOT NULL,
    app_id            character varying(36)       NOT NULL,
    ref_id            character varying(128),
    key_gen_dtimes    timestamp without time zone,
    key_expire_dtimes timestamp without time zone,
    status_code       character varying(36),
    lang_code         character varying(3),
    cr_by             character varying(256)      NOT NULL,
    cr_dtimes         timestamp without time zone NOT NULL,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    cert_thumbprint   character varying(100),
    uni_ident         character varying(50),
    CONSTRAINT pk_keymals_id PRIMARY KEY (id),
    CONSTRAINT uni_ident_const UNIQUE (uni_ident)
);

CREATE TABLE IF NOT EXISTS key_store (
    id                character varying(36)       NOT NULL,
    master_key        character varying(36)       NOT NULL,
    private_key       character varying(2500)     NOT NULL,
    certificate_data  character varying           NOT NULL,
    cr_by             character varying(256)      NOT NULL,
    cr_dtimes         timestamp without time zone NOT NULL,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    CONSTRAINT pk_keystr_id PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS key_policy_def (
    app_id                character varying(36)       NOT NULL,
    key_validity_duration smallint,
    is_active             boolean                     NOT NULL,
    pre_expire_days       smallint,
    access_allowed        character varying(1024),
    cr_by                 character varying(256)      NOT NULL,
    cr_dtimes             timestamp without time zone NOT NULL,
    upd_by                character varying(256),
    upd_dtimes            timestamp without time zone,
    is_deleted            boolean                     DEFAULT false,
    del_dtimes            timestamp without time zone,
    CONSTRAINT pk_keypdef_id PRIMARY KEY (app_id)
);

-- Key policies required by mock-identity-system AppConfig.run() on startup
INSERT INTO mockidentitysystem.key_policy_def
  (app_id, key_validity_duration, is_active, pre_expire_days, access_allowed, cr_by, cr_dtimes)
VALUES
  ('ROOT',                       3650, true, 90, null, 'System', NOW()),
  ('MOCK_AUTHENTICATION_SERVICE', 730, true, 90, null, 'System', NOW())
ON CONFLICT (app_id) DO NOTHING;

-- Application tables for mock-identity-system
-- (hibernate.hbm2ddl.auto=none — must be created here, Hibernate will NOT create them)
CREATE TABLE IF NOT EXISTS mock_identity (
    individual_id  character varying(256) NOT NULL,
    identity_json  TEXT,
    CONSTRAINT pk_mock_identity PRIMARY KEY (individual_id)
);

CREATE TABLE IF NOT EXISTS kyc_auth (
    kyc_token                   character varying(256)      NOT NULL,
    partner_specific_user_token character varying(256),
    response_time               timestamp without time zone,
    validity                    smallint,
    transaction_id              character varying(256),
    individual_id               character varying(256),
    CONSTRAINT pk_kyc_auth PRIMARY KEY (kyc_token)
);

CREATE TABLE IF NOT EXISTS verified_claim (
    id              character varying(36)       NOT NULL,
    individual_id   character varying(256),
    claim           character varying(256),
    trust_framework character varying(256),
    detail          TEXT,
    cr_date_time    timestamp without time zone,
    upd_date_time   timestamp without time zone,
    is_active       boolean                     DEFAULT true,
    created_by      character varying(256),
    CONSTRAINT pk_verified_claim PRIMARY KEY (id)
);

-- Seed identity for test UIN used in api-test-inji.sh (OTP is always 111111 in mock)
INSERT INTO mockidentitysystem.mock_identity (individual_id, identity_json)
VALUES (
  '5860356276',
  '{"individualId":"5860356276","fullName":[{"language":"eng","value":"Juan Gomez"}],"givenName":[{"language":"eng","value":"Juan"}],"familyName":[{"language":"eng","value":"Gomez"}],"gender":[{"language":"eng","value":"MLE"}],"dateOfBirth":"1990/01/15","email":"juan.gomez@example.com","phone":"9876543210","preferredLang":"eng","password":"e1wDlA0kTkqBr3SLzirV+g=="}')
ON CONFLICT (individual_id) DO NOTHING;

RESET search_path;

-- Keymanager tables for esignet
-- (ddl-auto=none so we must create these manually with correct column sizes)
SET search_path TO esignet;

CREATE TABLE IF NOT EXISTS key_alias (
    id                character varying(36)       NOT NULL,
    app_id            character varying(36)       NOT NULL,
    ref_id            character varying(128),
    key_gen_dtimes    timestamp without time zone,
    key_expire_dtimes timestamp without time zone,
    status_code       character varying(36),
    lang_code         character varying(3),
    cr_by             character varying(256)      NOT NULL,
    cr_dtimes         timestamp without time zone NOT NULL,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    cert_thumbprint   character varying(128),
    uni_ident         character varying(128),
    CONSTRAINT pk_esignet_keymals_id PRIMARY KEY (id),
    CONSTRAINT esignet_uni_ident_const UNIQUE (uni_ident)
);

CREATE TABLE IF NOT EXISTS key_store (
    id                character varying(36)       NOT NULL,
    master_key        character varying(36)       NOT NULL,
    private_key       character varying(2500)     NOT NULL,
    certificate_data  character varying           NOT NULL,
    cr_by             character varying(256)      NOT NULL,
    cr_dtimes         timestamp without time zone NOT NULL,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    CONSTRAINT pk_esignet_keystr_id PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS key_policy_def (
    app_id                character varying(36)       NOT NULL,
    key_validity_duration smallint,
    is_active             boolean                     NOT NULL,
    pre_expire_days       smallint,
    access_allowed        character varying(1024),
    cr_by                 character varying(256)      NOT NULL,
    cr_dtimes             timestamp without time zone NOT NULL,
    upd_by                character varying(256),
    upd_dtimes            timestamp without time zone,
    is_deleted            boolean                     DEFAULT false,
    del_dtimes            timestamp without time zone,
    CONSTRAINT pk_esignet_keypdef_id PRIMARY KEY (app_id)
);

-- Key policies required by esignet AppConfig.run() on startup
INSERT INTO esignet.key_policy_def
  (app_id, key_validity_duration, is_active, pre_expire_days, access_allowed, cr_by, cr_dtimes)
VALUES
  ('ROOT',         3650, true, 90, null, 'System', NOW()),
  ('OIDC_SERVICE',  730, true, 90, null, 'System', NOW()),
  ('OIDC_PARTNER',  730, true, 90, null, 'System', NOW())
ON CONFLICT (app_id) DO NOTHING;

-- OIDC client registry (ClientManagementServiceImpl reads this table)
-- Column names confirmed by decompiling ClientDetail.class from client-management-service-impl-1.5.1.jar:
--   auth_methods (NOT client_auth_methods), cr_dtimes (NOT createdtimes), upd_dtimes (NOT updatedtimes)
-- public_key is jsonb in the entity annotation but text works identically for read/write in psql.
-- The inji-certify-client row is seeded here using the JWK from oidckeystore.p12 (CN=inji-certify-poc).
-- init-inji.sh re-runs this upsert after eSignet starts so the JWK stays current on re-deploys.
CREATE TABLE IF NOT EXISTS client_detail (
    id            character varying(256)      NOT NULL,
    name          character varying(256)      NOT NULL,
    rp_id         character varying(256),
    logo_uri      character varying(2048),
    redirect_uris character varying(8192)     NOT NULL,
    public_key    TEXT                        NOT NULL,
    claims        character varying(4096),
    acr_values    character varying(1024),
    status        character varying(64)       NOT NULL,
    grant_types   character varying(1024)     NOT NULL,
    auth_methods  character varying(1024),
    cr_dtimes     timestamp without time zone,
    upd_dtimes    timestamp without time zone,
    CONSTRAINT pk_esignet_client_detail PRIMARY KEY (id)
);

-- inji-certify-client: OIDC client registered in eSignet for Certify OID4VCI flow.
-- The JWK public_key must match the keypair in oidckeystore.p12 (alias oidckeystore).
-- init-inji.sh extracts the live JWK at deploy time and upserts this row so it stays
-- in sync when the keystore is regenerated (e.g. after a full redeploy).
-- redirect_uris must include both the web URL (http://<VPS_IP>:3001/home) and the
-- mobile deep-link (io.mosip.residentapp://mosip/home) used by Inji mobile wallet.
INSERT INTO esignet.client_detail
  (id, name, rp_id, logo_uri, redirect_uris, public_key, claims, acr_values,
   status, grant_types, auth_methods, cr_dtimes, upd_dtimes)
VALUES (
  'inji-certify-client',
  'Inji Certify Client',
  'inji-certify-client',
  'LOGO_URI_PLACEHOLDER',
  '["REDIRECT_URI_WEB_PLACEHOLDER","io.mosip.residentapp://mosip/home"]',
  'JWK_PLACEHOLDER',
  '["name","email","birthdate","gender","phone_number"]',
  '["mosip:idp:acr:generated-code","mosip:idp:acr:linked-wallet"]',
  'ACTIVE',
  '["authorization_code"]',
  '["private_key_jwt"]',
  NOW(), NOW()
) ON CONFLICT (id) DO UPDATE SET
  public_key   = EXCLUDED.public_key,
  logo_uri     = EXCLUDED.logo_uri,
  redirect_uris = EXCLUDED.redirect_uris,
  upd_dtimes   = NOW();

RESET search_path;

-- Keymanager tables for mimoto
-- uni_ident must be varchar(512) — Hibernate's entity maps it at 32 which is too small
-- for the UUID-derived unique identifier generated by MOSIP's key manager.
-- Creating the table here before mimoto starts prevents Hibernate ddl-auto=update
-- from creating it with the wrong column size.
SET search_path TO mimoto;

CREATE TABLE IF NOT EXISTS key_alias (
    id                character varying(36)       NOT NULL,
    app_id            character varying(36)       NOT NULL,
    ref_id            character varying(36),
    key_gen_dtimes    timestamp(6) without time zone,
    key_expire_dtimes timestamp(6) without time zone,
    status_code       character varying(36),
    cert_thumbprint   character varying(128),
    uni_ident         character varying(512),
    cr_by             character varying(256),
    cr_dtimes         timestamp(6) without time zone,
    upd_by            character varying(256),
    upd_dtimes        timestamp(6) without time zone,
    is_deleted        boolean,
    del_dtimes        timestamp(6) without time zone,
    CONSTRAINT key_alias_pkey PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS key_store (
    id                character varying(36)       NOT NULL,
    master_key        character varying(255),
    private_key       character varying(255),
    certificate_data  character varying(255),
    cr_by             character varying(256),
    cr_dtimes         timestamp(6) without time zone,
    upd_by            character varying(256),
    upd_dtimes        timestamp(6) without time zone,
    is_deleted        boolean,
    del_dtimes        timestamp(6) without time zone,
    CONSTRAINT key_store_pkey PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS key_policy_def (
    app_id                character varying(36)       NOT NULL,
    key_validity_duration integer,
    is_active             boolean,
    pre_expire_days       integer,
    access_allowed        character varying(255),
    cr_by                 character varying(256),
    cr_dtimes             timestamp(6) without time zone,
    upd_by                character varying(256),
    upd_dtimes            timestamp(6) without time zone,
    is_deleted            boolean,
    del_dtimes            timestamp(6) without time zone,
    CONSTRAINT key_policy_def_pkey PRIMARY KEY (app_id)
);

-- Key policies required by mimoto KeyManagerConfig.run() on startup
INSERT INTO mimoto.key_policy_def
  (app_id, key_validity_duration, is_active, pre_expire_days, access_allowed, cr_by, cr_dtimes)
VALUES
  ('ROOT',     3650, true, 60, 'NA', 'cdpi-setup', NOW()),
  ('KERNEL',   3650, true, 60, 'NA', 'cdpi-setup', NOW()),
  ('MIMOTO',    730, true, 60, 'NA', 'cdpi-setup', NOW()),
  ('RESIDENT',  730, true, 60, 'NA', 'cdpi-setup', NOW())
ON CONFLICT (app_id) DO NOTHING;

RESET search_path;

-- Keymanager tables for certify
-- certify uses ddl-auto=update (Hibernate creates tables), but with wrong column sizes.
-- Pre-creating the tables here ensures correct column sizes before certify starts.
-- key_store.certificate_data and private_key must be TEXT — certificate DER is larger than 255 chars.
-- key_alias.uni_ident must be varchar(512) — same UUID-derived identifier issue as mimoto.
SET search_path TO certify;

CREATE TABLE IF NOT EXISTS key_alias (
    id                character varying(36)       NOT NULL,
    app_id            character varying(36)       NOT NULL,
    ref_id            character varying(128),
    key_gen_dtimes    timestamp without time zone,
    key_expire_dtimes timestamp without time zone,
    status_code       character varying(36),
    cert_thumbprint   character varying(128),
    uni_ident         character varying(512),
    cr_by             character varying(256),
    cr_dtimes         timestamp without time zone,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    CONSTRAINT certify_key_alias_pkey PRIMARY KEY (id),
    CONSTRAINT certify_uni_ident_const UNIQUE (uni_ident)
);

CREATE TABLE IF NOT EXISTS key_store (
    id                character varying(36)       NOT NULL,
    master_key        character varying(36),
    private_key       TEXT,
    certificate_data  TEXT,
    cr_by             character varying(256),
    cr_dtimes         timestamp without time zone,
    upd_by            character varying(256),
    upd_dtimes        timestamp without time zone,
    is_deleted        boolean                     DEFAULT false,
    del_dtimes        timestamp without time zone,
    CONSTRAINT certify_key_store_pkey PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS key_policy_def (
    app_id                character varying(36)       NOT NULL,
    key_validity_duration smallint,
    is_active             boolean                     NOT NULL DEFAULT true,
    pre_expire_days       smallint,
    access_allowed        character varying(1024),
    cr_by                 character varying(256)      NOT NULL DEFAULT 'System',
    cr_dtimes             timestamp without time zone NOT NULL DEFAULT NOW(),
    upd_by                character varying(256),
    upd_dtimes            timestamp without time zone,
    is_deleted            boolean                     DEFAULT false,
    del_dtimes            timestamp without time zone,
    CONSTRAINT certify_key_policy_def_pkey PRIMARY KEY (app_id)
);

-- ShedLock table used by StatusListUpdateBatchJob scheduled task
CREATE TABLE IF NOT EXISTS shedlock (
    name       CHARACTER VARYING(64)       NOT NULL,
    lock_until TIMESTAMP WITHOUT TIME ZONE,
    locked_at  TIMESTAMP WITHOUT TIME ZONE,
    locked_by  CHARACTER VARYING(255),
    PRIMARY KEY (name)
);

-- Key policies required by certify AppConfig.initKeys() on startup.
-- Discovered by decompiling AppConfig.class — these are all the app_ids checked:
--   ROOT, CERTIFY_SERVICE (master), CERTIFY_SERVICE#TRANSACTION_CACHE (uses BASE policy),
--   CERTIFY_PARTNER, CERTIFY_VC_SIGN_RSA, CERTIFY_VC_SIGN_EC_K1, CERTIFY_VC_SIGN_EC_R1,
--   CERTIFY_VC_SIGN_ED25519.
INSERT INTO certify.key_policy_def
  (app_id, key_validity_duration, is_active, pre_expire_days, access_allowed, cr_by, cr_dtimes)
VALUES
  ('ROOT',                  3650, true, 90, null, 'System', NOW()),
  ('BASE',                   730, true, 30, null, 'System', NOW()),
  ('CERTIFY_SERVICE',        730, true, 90, null, 'System', NOW()),
  ('CERTIFY_PARTNER',        730, true, 90, null, 'System', NOW()),
  ('CERTIFY_VC_SIGN_RSA',    730, true, 90, null, 'System', NOW()),
  ('CERTIFY_VC_SIGN_EC_K1',  730, true, 90, null, 'System', NOW()),
  ('CERTIFY_VC_SIGN_EC_R1',  730, true, 90, null, 'System', NOW()),
  ('CERTIFY_VC_SIGN_ED25519', 730, true, 90, null, 'System', NOW())
ON CONFLICT (app_id) DO NOTHING;

RESET search_path;

-- NOTE: The passwords above are placeholders.
-- The actual passwords are set via environment variables in the service configs.
