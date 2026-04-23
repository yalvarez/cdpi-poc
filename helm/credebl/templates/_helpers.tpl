{{/*
Expand the name of the chart.
*/}}
{{- define "credebl.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "credebl.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels for a given component (pass component name as .component).
*/}}
{{- define "credebl.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .release }}
{{- end }}

{{/*
Image reference helper — uses global registry + tag unless overridden.
Usage: {{ include "credebl.image" (dict "registry" .Values.global.imageRegistry "name" "api-gateway" "tag" .Values.global.imageTag "pullPolicy" .Values.global.imagePullPolicy) }}
*/}}
{{- define "credebl.image" -}}
image: {{ .registry }}/{{ .name }}:{{ .tag }}
imagePullPolicy: {{ .pullPolicy }}
{{- end }}

{{/*
Database hostname — returns internal service name or external host.
*/}}
{{- define "credebl.dbHost" -}}
{{- if .Values.postgres.enabled -}}
postgres
{{- else -}}
{{ .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{/*
Database URL — full postgresql:// connection string.
*/}}
{{- define "credebl.dbUrl" -}}
postgresql://{{ if .Values.postgres.enabled }}$(POSTGRES_USER){{ else }}{{ .Values.externalDatabase.user }}{{ end }}:$(POSTGRES_PASSWORD)@{{ include "credebl.dbHost" . }}:{{ if .Values.postgres.enabled }}5432{{ else }}{{ .Values.externalDatabase.port }}{{ end }}/{{ if .Values.postgres.enabled }}$(POSTGRES_DB){{ else }}{{ .Values.externalDatabase.name }}{{ end }}
{{- end }}

{{/*
Redis hostname.
*/}}
{{- define "credebl.redisHost" -}}
{{- if .Values.redis.enabled -}}
redis
{{- else -}}
{{ .Values.externalRedis.host }}
{{- end }}
{{- end }}

{{/*
Keycloak internal URL (always the in-cluster service, regardless of public URL).
Used by services that call Keycloak server-to-server.
*/}}
{{- define "credebl.keycloakInternalUrl" -}}
{{- if .Values.keycloak.enabled -}}
http://keycloak:8080/
{{- else -}}
{{ .Values.oidc.issuerUrl }}
{{- end }}
{{- end }}

{{/*
Keycloak public URL (browser-facing).
*/}}
{{- define "credebl.keycloakPublicUrl" -}}
{{- if .Values.keycloak.publicUrl -}}
{{ .Values.keycloak.publicUrl }}
{{- else -}}
{{ .Values.credebl.appProtocol }}://auth.{{ .Values.global.domain }}
{{- end }}
{{- end }}

{{/*
API endpoint (no protocol prefix — CREDEBL uses this as host:port reference).
*/}}
{{- define "credebl.apiEndpoint" -}}
{{- if .Values.credebl.apiEndpoint -}}
{{ .Values.credebl.apiEndpoint }}
{{- else -}}
api.{{ .Values.global.domain }}
{{- end }}
{{- end }}

{{/*
Studio URL (full URL with protocol).
*/}}
{{- define "credebl.studioUrl" -}}
{{- if .Values.credebl.studioUrl -}}
{{ .Values.credebl.studioUrl }}
{{- else -}}
{{ .Values.credebl.appProtocol }}://studio.{{ .Values.global.domain }}
{{- end }}
{{- end }}

{{/*
Schema file server internal URL.
*/}}
{{- define "credebl.schemaFileServerUrl" -}}
http://schema-file-server:4000
{{- end }}

{{/*
S3 endpoint — internal MinIO or external S3-compatible.
*/}}
{{- define "credebl.s3Endpoint" -}}
{{- if .Values.minio.enabled -}}
http://minio:9000
{{- else -}}
{{ .Values.externalS3.endpoint }}
{{- end }}
{{- end }}

{{/*
SMTP host — internal Mailpit or external SMTP.
*/}}
{{- define "credebl.smtpHost" -}}
{{- if .Values.mailpit.enabled -}}
mailpit
{{- else -}}
{{ .Values.smtp.host }}
{{- end }}
{{- end }}

{{/*
SMTP port.
*/}}
{{- define "credebl.smtpPort" -}}
{{- if .Values.mailpit.enabled -}}
1025
{{- else -}}
{{ .Values.smtp.port }}
{{- end }}
{{- end }}

{{/*
hostAliases block — maps the public API domain to the Ingress controller IP
so internal service-to-service calls (e.g. agent-service → api-gateway via
stored agentEndPoint URL) resolve within the cluster.
Only rendered when global.ingressIP is set.
*/}}
{{- define "credebl.hostAliases" -}}
{{- if .Values.global.ingressIP }}
hostAliases:
  - ip: {{ .Values.global.ingressIP | quote }}
    hostnames:
      - {{ include "credebl.apiEndpoint" . | quote }}
{{- end }}
{{- end }}

{{/*
Standard environment variables shared by all CREDEBL microservices.
Renders as a list of env entries that can be included in any container spec.
*/}}
{{- define "credebl.commonEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: DATABASE_URL
- name: POOL_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: DATABASE_URL
- name: REDIS_HOST
  value: {{ include "credebl.redisHost" . | quote }}
- name: REDIS_PORT
  value: {{ if .Values.redis.enabled }}"6379"{{ else }}{{ .Values.externalRedis.port | quote }}{{ end }}
- name: REDIS_PASSWORD
  value: ""
- name: NATS_URL
  value: "nats://nats:4222"
- name: NATS_AUTH_TYPE
  value: "none"
- name: CRYPTO_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: CRYPTO_PRIVATE_KEY
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: JWT_SECRET
- name: JWT_TOKEN_SECRET
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: JWT_TOKEN_SECRET
- name: JWT_EXPIRY
  value: "1d"
- name: KEYCLOAK_DOMAIN
  value: {{ include "credebl.keycloakInternalUrl" . | quote }}
- name: KEYCLOAK_ADMIN_URL
  value: {{ if .Values.keycloak.enabled }}"http://keycloak:8080"{{ else }}{{ .Values.oidc.issuerUrl | quote }}{{ end }}
- name: KEYCLOAK_PUBLIC_URL
  value: {{ include "credebl.keycloakPublicUrl" . | quote }}
- name: KEYCLOAK_MASTER_REALM
  value: "master"
- name: KEYCLOAK_REALM
  value: {{ .Values.credebl.keycloakRealm | quote }}
- name: KEYCLOAK_CLIENT_ID
  value: {{ .Values.credebl.keycloakClientId | quote }}
- name: KEYCLOAK_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: KEYCLOAK_CLIENT_SECRET
- name: KEYCLOAK_MANAGEMENT_CLIENT_ID
  value: {{ .Values.credebl.keycloakManagementClientId | quote }}
- name: KEYCLOAK_MANAGEMENT_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: KEYCLOAK_CLIENT_SECRET
- name: PLATFORM_ADMIN_KEYCLOAK_ID
  value: {{ .Values.credebl.keycloakManagementClientId | quote }}
- name: PLATFORM_ADMIN_KEYCLOAK_SECRET
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: KEYCLOAK_CLIENT_SECRET
- name: PLATFORM_ADMIN_EMAIL
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: PLATFORM_ADMIN_EMAIL
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_SECRET_ACCESS_KEY
- name: AWS_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_SECRET_ACCESS_KEY
- name: AWS_PUBLIC_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_ACCESS_KEY_ID
- name: AWS_PUBLIC_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: AWS_SECRET_ACCESS_KEY
- name: AWS_REGION
  value: {{ if .Values.minio.enabled }}"us-east-1"{{ else }}{{ .Values.externalS3.region | quote }}{{ end }}
- name: AWS_PUBLIC_REGION
  value: {{ if .Values.minio.enabled }}"us-east-1"{{ else }}{{ .Values.externalS3.region | quote }}{{ end }}
- name: AWS_ENDPOINT
  value: {{ include "credebl.s3Endpoint" . | quote }}
- name: AWS_S3_STOREOBJECT_ENDPOINT
  value: {{ include "credebl.s3Endpoint" . | quote }}
- name: S3_BUCKET_NAME
  value: {{ if .Values.minio.enabled }}"credebl-bucket"{{ else }}{{ .Values.externalS3.bucket | quote }}{{ end }}
- name: SENDGRID_API_KEY
  valueFrom:
    secretKeyRef:
      name: credebl-secrets
      key: SENDGRID_API_KEY
- name: SMTP_HOST
  value: {{ include "credebl.smtpHost" . | quote }}
- name: SMTP_PORT
  value: {{ include "credebl.smtpPort" . | quote }}
- name: SMTP_SECURE
  value: {{ if .Values.mailpit.enabled }}"false"{{ else }}{{ .Values.smtp.secure | quote }}{{ end }}
- name: EMAIL_FROM
  value: {{ if .Values.mailpit.enabled }}"noreply@credebl.local"{{ else }}{{ .Values.smtp.from | quote }}{{ end }}
- name: API_GATEWAY_PROTOCOL
  value: {{ .Values.credebl.appProtocol | quote }}
- name: API_GATEWAY_HOST
  value: "0.0.0.0"
- name: API_GATEWAY_PORT
  value: "5000"
- name: PLATFORM_WEB_URL
  value: {{ printf "%s://%s" .Values.credebl.appProtocol (include "credebl.apiEndpoint" .) | quote }}
- name: FRONT_END_URL
  value: {{ printf "%s://%s" .Values.credebl.appProtocol (include "credebl.apiEndpoint" .) | quote }}
- name: STUDIO_URL
  value: {{ include "credebl.studioUrl" . | quote }}
- name: SCHEMA_FILE_SERVER_URL
  value: {{ include "credebl.schemaFileServerUrl" . | quote }}
- name: SCHEMA_FILE_SERVER_PORT
  value: "4000"
- name: LEDGER_URL
  value: {{ .Values.credebl.ledgerUrl | quote }}
- name: GENESIS_URL
  value: {{ .Values.credebl.genesisUrl | quote }}
- name: TAILS_FILE_SERVER
  value: {{ .Values.credebl.tailsFileServer | quote }}
- name: MOBILE_APP_NAME
  value: {{ .Values.credebl.mobileAppName | quote }}
- name: MOBILE_APP
  value: {{ .Values.credebl.mobileAppName | quote }}
- name: MOBILE_APP_DOWNLOAD_URL
  value: {{ .Values.credebl.mobileAppDownloadUrl | quote }}
- name: PLAY_STORE_DOWNLOAD_LINK
  value: {{ .Values.credebl.playStoreDownloadLink | quote }}
- name: PLATFORM_NAME
  value: "CREDEBL"
- name: POWERED_BY
  value: "CDPI"
- name: ORGANIZATION
  value: "credebl"
- name: CONTEXT
  value: "platform"
- name: APP
  value: "api"
- name: CONSOLE_LOG_FLAG
  value: "true"
- name: LOG_LEVEL
  value: "info"
- name: CREDENTIAL_FORMAT
  value: "SD_JWT_VC"
- name: AGENT_PROTOCOL
  value: "http"
{{- end }}
