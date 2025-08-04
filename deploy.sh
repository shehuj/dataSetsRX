#!/bin/bash

set -e

echo "Starting deployment to EC2..."

# Configuration
APP_NAME="patient-data-collection"
DEPLOY_USER="ec2-user"
SERVER_IP="YOUR_EC2_IP_HERE"
DEPLOY_PATH="/opt/${APP_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if SSH key exists
if [ ! -f "$HOME/.ssh/your-ec2-key.pem" ]; then
    print_error "SSH key not found. Please ensure your EC2 key pair is at ~/.ssh/your-ec2-key.pem"
    exit 1
fi

# Create deployment package
print_status "Creating deployment package..."
tar -czf ${APP_NAME}.tar.gz \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='*.log' \
    --exclude='patient_data.db' \
    package.json server.js setup-database.js Dockerfile docker-compose.yml nginx.conf

# Upload to EC2
print_status "Uploading to EC2..."
scp -i ~/.ssh/your-ec2-key.pem ${APP_NAME}.tar.gz ${DEPLOY_USER}@${SERVER_IP}:/tmp/

# Deploy on EC2
print_status "Deploying on EC2..."
ssh -i ~/.ssh/your-ec2-key.pem ${DEPLOY_USER}@${SERVER_IP} << EOF
    set -e
    
    # Create deployment directory
    sudo mkdir -p ${DEPLOY_PATH}
    sudo chown ${DEPLOY_USER}:${DEPLOY_USER} ${DEPLOY_PATH}
    
    # Extract and setup
    cd ${DEPLOY_PATH}
    tar -xzf /tmp/${APP_NAME}.tar.gz
    
    # Install dependencies
    npm install --production
    
    # Setup database
    node setup-database.js
    
    # Setup systemd service if it doesn't exist
    if [ ! -f /etc/systemd/system/${APP_NAME}.service ]; then
        sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null <<EOL
[Unit]
Description=Patient Data Collection API
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
WorkingDirectory=${DEPLOY_PATH}
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
EOL
        
        sudo systemctl daemon-reload
        sudo systemctl enable ${APP_NAME}
    fi
    
    # Restart service
    sudo systemctl restart ${APP_NAME}
    
    # Check status
    sleep 5
    sudo systemctl status ${APP_NAME} --no-pager
    
    echo "Deployment completed successfully!"
EOF

# Cleanup
rm ${APP_NAME}.tar.gz

print_status "Deployment completed! Your API should be running at http://${SERVER_IP}:3000"
print_status "Health check: curl http://${SERVER_IP}:3000/health"