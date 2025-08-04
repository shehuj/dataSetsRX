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