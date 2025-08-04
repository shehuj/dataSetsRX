#!/bin/bash
# setup-jenkins-server.sh - Complete Jenkins server setup

set -e

echo "🚀 Setting up Jenkins CI/CD Server..."

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root"
   exit 1
fi

# Update system
print_header "Updating system packages..."
sudo yum update -y

# Install Java (required for Jenkins)
print_header "Installing Java 11..."
sudo yum install -y java-11-openjdk java-11-openjdk-devel

# Set JAVA_HOME
echo 'export JAVA_HOME=/usr/lib/jvm/java-11-openjdk' | sudo tee -a /etc/environment
source /etc/environment

# Install Jenkins
print_header "Installing Jenkins..."
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins

# Start and enable Jenkins
sudo systemctl start jenkins
sudo systemctl enable jenkins

# Install Docker
print_header "Installing Docker..."
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker

# Add jenkins user to docker group
sudo usermod -a -G docker jenkins

# Install Docker Compose
print_header "Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install Node.js (for local testing)
print_header "Installing Node.js..."
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs

# Install Git
print_header "Installing Git..."
sudo yum install -y git

# Install additional tools
print_header "Installing additional tools..."
sudo yum install -y curl wget unzip htop

# Configure firewall
print_header "Configuring firewall..."
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --reload

# Restart Jenkins to apply group changes
print_header "Restarting Jenkins..."
sudo systemctl restart jenkins

# Wait for Jenkins to start
print_status "Waiting for Jenkins to start..."
sleep 30

# Get initial admin password
JENKINS_PASSWORD=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "Not found")

print_status "Jenkins setup completed!"
print_status "Access Jenkins at: http://$(curl -s ipinfo.io/ip):8080"
print_status "Initial admin password: $JENKINS_PASSWORD"

print_status "Next steps:"
print_status "1. Access Jenkins web interface"
print_status "2. Complete initial setup wizard"
print_status "3. Install recommended plugins"
print_status "4. Configure tools and credentials as per the guide"