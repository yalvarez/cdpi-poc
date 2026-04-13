param(
  [Parameter(Mandatory = $true)]
  [string]$SshTarget,

  [Parameter(Mandatory = $true)]
  [string]$VpsIp,

  [Parameter(Mandatory = $false)]
  [string]$RecipientEmail = 'ysaias@cdpi.dev',

  [Parameter(Mandatory = $false)]
  [string]$RemoteRepoPath = '~/cdpi-poc',

  [Parameter(Mandatory = $false)]
  [string]$AdminEmail = 'admin@cdpi-poc.local',

  [Parameter(Mandatory = $false)]
  [string]$AdminPassword = 'changeme',

  [Parameter(Mandatory = $false)]
  [string]$CryptoPrivateKey = 'cdpi-poc-crypto-key-change-me',

  [Parameter(Mandatory = $false)]
  [string]$SchemaFileServerUrl = 'http://schema-file-server:4000/schemas/'
)

$ErrorActionPreference = 'Stop'

function Assert-CommandExists {
  param([string]$CommandName)
  if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $CommandName"
  }
}

Assert-CommandExists -CommandName 'ssh'

function Escape-ForBashSingleQuotes {
  param([string]$Value)
  return $Value.Replace("'", "'`"'`"'")
}

$escapedRepoPath = Escape-ForBashSingleQuotes -Value $RemoteRepoPath
$escapedRecipient = Escape-ForBashSingleQuotes -Value $RecipientEmail
$escapedAdminEmail = Escape-ForBashSingleQuotes -Value $AdminEmail
$escapedAdminPassword = Escape-ForBashSingleQuotes -Value $AdminPassword
$escapedCryptoKey = Escape-ForBashSingleQuotes -Value $CryptoPrivateKey
$escapedSchemaUrl = Escape-ForBashSingleQuotes -Value $SchemaFileServerUrl
$escapedVpsIp = Escape-ForBashSingleQuotes -Value $VpsIp

$remoteCommand = @"
set -euo pipefail
cd '$escapedRepoPath'

for c in bash curl jq openssl docker; do
  command -v "\$c" >/dev/null 2>&1 || {
    echo "Missing required command on VPS: \$c" >&2
    exit 1
  }
done

if [ ! -f credebl/.env.example ]; then
  echo "Missing file: credebl/.env.example" >&2
  exit 1
fi

if [ ! -f scripts/credebl-api-e2e.sh ]; then
  echo "Missing file: scripts/credebl-api-e2e.sh" >&2
  exit 1
fi

echo "[1/3] Starting CREDEBL services"
docker compose --env-file credebl/.env.example -f credebl/docker-compose.yml up -d

echo "[2/3] Running health check"
bash scripts/health-check.sh

echo "[3/3] Running API E2E script"
ADMIN_EMAIL='$escapedAdminEmail' \
ADMIN_PASSWORD='$escapedAdminPassword' \
CRYPTO_PRIVATE_KEY='$escapedCryptoKey' \
SCHEMA_FILE_SERVER_URL='$escapedSchemaUrl' \
bash scripts/credebl-api-e2e.sh '$escapedVpsIp' '$escapedRecipient'
"@

Write-Host "Executing on VPS: $SshTarget"
$remoteCommandLf = $remoteCommand -replace "`r`n", "`n"
$remoteCommandBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteCommandLf))
ssh $SshTarget "bash -lc 'echo $remoteCommandBase64 | base64 -d | bash'"
