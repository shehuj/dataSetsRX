#!/usr/bin/env bash
# setup-jenkins-ubuntu.sh — Installs Jenkins 2.516.x, Java 17+, Docker CE, Docker Compose v2, Node 18, Git, and configures UFW firewall
# Target: Ubuntu 22.04 / 24.04 on EC2 (run as non-root 'ubuntu' user with sudo privileges)

set -euo pipefail
trap 'echo "[FATAL] Error on line \$LINENO." >&2; exit 1' ERR

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
step(){ echo -e "${BLUE}[STEP]${NC} $*"; }
info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [ "$EUID" -eq 0 ]; then
  err "Please run as a non-root user with sudo (e.g. 'ubuntu'), not as root."
  exit 1
fi

step "Updating APT and upgrading system"
sudo apt update -q
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y -q

step "Installing Java 17 and Java 21 (required by Jenkins 2.463+)"
sudo apt install -y openjdk-17-jdk openjdk-21-jdk

step "Configuring default Java to version-17 via update-alternatives"
sudo update-alternatives --install /usr/bin/java   java   /usr/lib/jvm/java-17-openjdk-amd64/bin/java  1100
sudo update-alternatives --install /usr/bin/java   java   /usr/lib/jvm/java-21-openjdk-amd64/bin/java   1090
sudo update-alternatives --install /usr/bin/javac  javac  /usr/lib/jvm/java-17-openjdk-amd64/bin/javac  1100
sudo update-alternatives --install /usr/bin/javac  javac  /usr/lib/jvm/java-21-openjdk-amd64/bin/javac  1090
sudo update-alternatives --set java   /usr/lib/jvm/java-17-openjdk-amd64/bin/java
sudo update-alternatives --set javac  /usr/lib/jvm/java-17-openjdk-amd64/bin/javac

java -version 2>&1 | grep -Eq 'version "(17|21)\.' || {
  err "Java must be version 17 or 21. Run: sudo update-alternatives --config java"
  exit 1
}
info "Java validated: $(java -version 2>&1 | head -n1)"

step "Adding Jenkins official Debian repository"
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc >/dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null

step "Installing Jenkins 2.516.x LTS"
sudo apt update -q
sudo apt install -y jenkins

step "Patching Jenkins systemd (timeout + JAVA override)"
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/override.conf >/dev/null <<EOF
[Service]
TimeoutStartSec=180
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment=JENKINS_JAVA_CMD=\${JAVA_HOME}/bin/java
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now jenkins

step "Installing Docker CE and Compose plugin (official Docker repo)"
sudo apt remove -y docker docker.io docker-compose-plugin containerd runc || true
sudo apt install -y ca-certificates curl gnupg software-properties-common
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update -q
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo usermod -aG docker jenkins

if ! sudo -u jenkins docker compose version &>/dev/null; then
  warn "docker compose missing—installing manually"
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  sudo systemctl restart docker
  info "Installed docker compose fallback"
else
  info "Docker Compose available: $(sudo -u jenkins docker compose version | head -n1)"
fi

step "Installing Node.js 18 LTS"
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

step "Installing Git and utilities"
sudo apt install -y git wget unzip htop

step "Configuring UFW firewall (allow SSH and Jenkins)"
sudo apt install -y ufw
sudo ufw allow ssh
sudo ufw allow 8080/tcp
sudo ufw --force enable

step "Restarting Jenkins to apply all changes"
sudo systemctl restart jenkins
sleep 20

if systemctl is-active --quiet jenkins; then
  info "✅ Jenkins is running successfully"
else
  warn "Jenkins failed to start—run: sudo journalctl -u jenkins -n50"
fi

J_PASS=$(sudo head -n1 /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "UNKNOWN")
IP=$(hostname -I | awk '{print $1}')
info "Access Jenkins at: http://${IP}:8080"
info "Initial admin password: ${J_PASS}"
