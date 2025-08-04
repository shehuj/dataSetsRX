#!/bin/bash

# Run this script on your EC2 instance to set up the environment

set -e

echo "Setting up EC2 environment for Patient Data Collection API..."

# Update system
sudo yum update -y

# Install Node.js
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs

# Install additional tools
sudo yum install -y git curl wget htop

# Install Docker (optional, for containerized deployment)
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create application directory
sudo mkdir -p /opt/patient-data-collection
sudo chown ec2-user:ec2-user /opt/patient-data-collection

# Create logs directory
sudo mkdir -p /var/log/patient-data-collection
sudo chown ec2-user:ec2-user /var/log/patient-data-collection

# Setup firewall (if needed)
# sudo firewall-cmd --permanent --add-port=3000/tcp
# sudo firewall-cmd --reload

echo "EC2 environment setup completed!"
echo "You can now run the deploy.sh script from your local machine."
#!/usr/bin/env bash
#
# setup-ec2-env.sh — Provision Amazon Linux 2 or 2023 for
# Patient Data Collection API (Node.js 18, Docker, systemd, logrotate).

set -euo pipefail
trap 'echo "[FATAL] Error on line $LINENO."; exit 1' ERR

# ANSI colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_header(){ echo -e "${BLUE}[STEP]${NC} $*"; }
print_status(){ echo -e "${GREEN}[OK]${NC} $*"; }
print_warning(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error(){ echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -eq 0 ]]; then
  print_error "Run this script as non-root ('ec2-user'); sudo is used internally."
  exit 1
fi

print_header "Detecting Amazon Linux version..."
eval "$(grep '^VERSION_ID' /etc/os-release | tr -d '"' | sed 's/VERSION_ID=//' | awk '{print ($1=="2023"?"AL2023":"AL2")}' | sed 's/.*/VERSION=\0/')"
print_status "Detected $VERSION (within /etc/os-release)."

print_header "Updating system packages..."
sudo yum update -y -q

print_header "Installing build tools and utilities..."
sudo yum install -y -q git curl wget htop

### Node.js v18 Installation ###
print_header "Setting up Node.js v18.x"
if [[ "$VERSION" == "AL2023" ]]; then
  sudo yum install -y -q nodejs nodejs-npm  # AL2023 comes with Node‑18 native
  print_status "Installed system Node.js 18 (AL2023 namespace)."
else
  # Amazon Linux 2 lacks official Node‑18; use official NodeSource repo
  sudo yum install -y -q gcc-c++ make
  curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
  sudo yum install -y -q nodejs
  print_status "Installed Node.js 18 via NodeSource RPM (AL2 compat)."
fi

node -v | grep -q '^v18' || { print_error "Node.js v18 install failed"; exit 1; }

print_header "Creating application directories"
sudo mkdir -p /opt/patient-data-collection
sudo mkdir -p /var/log/patient-data-collection
sudo chown -R ec2-user:ec2-user /opt/patient-data-collection /var/log/patient-data-collection

### Docker + Docker Compose ###
print_header "Installing Docker"
if [[ "$VERSION" == "AL2" ]]; then
  sudo amazon-linux-extras install -y docker
else
  sudo yum install -y docker
fi

sudo systemctl enable docker --now
sudo usermod -aG docker ec2-user
print_status "Docker installed and ec2-user added to docker group."

print_header "Installing Docker Compose"
COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
sudo curl -fsSL "$COMPOSE_URL" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
print_status "Docker Compose binary installed."

### systemd Service ###
SERVICE_FILE="/etc/systemd/system/patient-data-collection.service"
print_header "Creating systemd service: $(basename "$SERVICE_FILE")"

sudo tee "$SERVICE_FILE" > /dev/null << 'EOF'
[Unit]
Description=Patient Data Collection API (Node.js)
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/patient-data-collection
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5

# Set a few ENV defaults — override with system-wide env file
Environment=NODE_ENV=production
Environment=PORT=3000

StandardOutput=append:/var/log/patient-data-collection/access.log
StandardError=append:/var/log/patient-data-collection/error.log

# Environment files can be set by dropping
# /etc/sysconfig/pdc.env or ~/.pdc.env
EnvironmentFile=-/etc/sysconfig/patient-data-collection.env
EnvironmentFile=-/home/ec2-user/.patient-data-collection.env

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable patient-data-collection
print_status "systemd service template created and enabled."

### Logrotate config ###
ROTATE_FILE="/etc/logrotate.d/patient-data-collection"
print_header "Configuring log rotation"
sudo tee "$ROTATE_FILE" > /dev/null << 'EOF'
/var/log/patient-data-collection/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF
print_status "Logrotate rule written to $ROTATE_FILE"

### .env template ###
ENV_DIVERT="/etc/sysconfig/patient-data-collection.env"
print_header "Writing env template: $ENV_DIVERT"
sudo tee "$ENV_DIVERT" > /dev/null << 'EOF'
# Patient Data Collection — Production environment file

# Application
NODE_ENV=production
PORT=3000
ALLOWED_ORIGIN=https://yourdomain.com

# Database (SQLite)
DATABASE_PATH=/opt/patient-data-collection/patient_data.db

# Secrets
# It's safer to inject secrets at launch time or via AWS Secrets Manager
# JWT_SECRET=changeme
EOF
sudo chown ec2-user:ec2-user "$ENV_DIVERT"
print_status "Environment file template created."

### Deploy helper ###
print_header "Creating local deploy helper: deploy.sh"
cat << 'EOF' > /opt/patient-data-collection/deploy.sh
#!/usr/bin/env bash
# Run this from your dev machine to push and deploy new releases

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <git-ref> [--reinstall]"
  exit 1
fi

REF="$1"
REINSTALL=${2:-}

# Archive source and send
git archive "$REF" | ssh ec2-user@YOUR_EC2_PUBLIC_DNS bash -s << 'ENDSSH'
  cd /opt/patient-data-collection
  rm -rf ./*
  tar -xz --strip-components=1
  npm ci  # or npm install
  if [[ "$2" == "--reinstall" ]]; then
    npm rebuild
  fi
  systemctl restart patient-data-collection
ENDSSH

echo "Deployment of $REF triggered."
EOF
sudo chmod +x /opt/patient-data-collection/deploy.sh
sudo chown ec2-user:ec2-user /opt/patient-data-collection/deploy.sh
print_status "deploy.sh helper script created."

### Initial service start ###
print_header "Starting service for the first time"
sudo systemctl start patient-data-collection
sleep 3
if sudo systemctl is-active patient-data-collection &> /dev/null; then
  print_status "API service is running under systemd."
else
  print_error "Service failed to start; check logs."
fi

print_status "EC2 setup complete! Visit: http://YOUR_SERVER_IP:3000"
