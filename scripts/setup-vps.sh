#!/usr/bin/env bash
# =============================================================================
# CDPI PoC — VPS Setup Script
# -----------------------------------------------------------------------------
# Run this ONCE on a fresh Ubuntu 22.04 / 24.04 VPS before deploying CREDEBL
# Tested on: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
#
# Usage:
#   chmod +x setup-vps.sh
#   sudo ./setup-vps.sh
# =============================================================================

set -euo pipefail

DOCKER_COMPOSE_VERSION="2.24.5"
REPO_DIR="/opt/cdpi-poc"

echo "============================================================"
echo " CDPI PoC — VPS Setup"
echo " $(date)"
echo "============================================================"

# ── 1. System update ─────────────────────────────────────────────────────────
echo ""
echo "[1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl \
  wget \
  git \
  jq \
  htop \
  ufw \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl \
  python3

# ── 2. Install Docker ─────────────────────────────────────────────────────────
echo ""
echo "[2/7] Installing Docker Engine..."
if command -v docker &>/dev/null; then
  echo "  Docker already installed: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  echo "  Docker installed: $(docker --version)"
fi

# ── 3. Configure firewall ─────────────────────────────────────────────────────
echo ""
echo "[3/7] Configuring firewall (ufw)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    comment 'HTTP reverse proxy / ACME challenge'
ufw allow 443/tcp   comment 'HTTPS reverse proxy'
ufw allow 3000/tcp  comment 'CREDEBL Studio'
ufw allow 5000/tcp  comment 'CREDEBL API Gateway'
ufw allow 8080/tcp  comment 'Keycloak OIDC'
ufw allow 9000/tcp  comment 'MinIO S3 API (credential offer storage)'
ufw allow 9011/tcp  comment 'MinIO Console'
ufw allow 9001/tcp  comment 'Credo agent inbound (DIDComm OOB)'
ufw allow 8025/tcp  comment 'Mailpit Web UI'
ufw allow 4000/tcp  comment 'Schema File Server'
ufw --force enable
echo "  Firewall configured. Open ports: 22, 80, 443, 3000, 5000, 8080, 9000, 9001, 9011, 8025, 4000"

# ── 4. Configure swap (helps with 8GB RAM + 20 containers) ───────────────────
echo ""
echo "[4/7] Configuring swap space (4GB)..."
if swapon --show | grep -q '/swapfile'; then
  echo "  Swap already configured"
else
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  sysctl -p
  echo "  4GB swap file created and activated"
fi

# ── 5. Docker daemon tuning ───────────────────────────────────────────────────
echo ""
echo "[5/7] Tuning Docker daemon for PoC..."
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF
systemctl restart docker
echo "  Docker daemon configured (log rotation, ulimits)"

# ── 6. Create working directory ───────────────────────────────────────────────
echo ""
echo "[6/7] Creating project directory..."
mkdir -p "$REPO_DIR"
chmod 755 "$REPO_DIR"
echo "  Project directory: $REPO_DIR"

# ── 7. Health check ───────────────────────────────────────────────────────────
echo ""
echo "[7/7] Running health checks..."
echo "  Docker:         $(docker --version)"
echo "  Docker Compose: $(docker compose version)"
echo "  Available RAM:  $(free -h | awk '/^Mem:/{print $2}')"
echo "  Available disk: $(df -h / | awk 'NR==2{print $4}') free of $(df -h / | awk 'NR==2{print $2}')"
echo "  Swap:           $(free -h | awk '/^Swap:/{print $2}')"

echo ""
echo "============================================================"
echo " VPS setup complete!"
echo "============================================================"
echo ""
echo " Next steps:"
echo "   1. Clone the CDPI PoC repository into $REPO_DIR"
echo "   2. cd $REPO_DIR"
echo "   3. bash scripts/init-credebl.sh"
echo "      (or configure credebl/.env manually and run docker compose up -d)"
echo ""
echo " Your VPS IP: $(curl -s ifconfig.me 2>/dev/null || echo 'run: curl ifconfig.me')"
echo ""
