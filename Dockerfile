# Dockerfile
FROM node:18-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --only=production

# Copy application code
COPY . .

# Create data directory for SQLite
RUN mkdir -p /app/data

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

# Start application
CMD ["npm", "start"]

# docker-compose.yml
version: '3.8'

services:
  patient-data-api:
    build: .
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - PORT=3000
      - ALLOWED_ORIGINS=https://yourdomain.com,https://app.yourdomain.com
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./ssl:/etc/nginx/ssl
    depends_on:
      - patient-data-api
    restart: unless-stopped

# nginx.conf
events {
    worker_connections 1024;
}

http {
    upstream api {
        server patient-data-api:3000;
    }

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        listen 80;
        server_name your-domain.com;
        
        # Redirect HTTP to HTTPS
        return 301 https://$server_name$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name your-domain.com;

        # SSL configuration (update paths as needed)
        ssl_certificate /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

        # Security headers
        add_header X-Frame-Options DENY;
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";

        location / {
            limit_req zone=api burst=20 nodelay;
            
            proxy_pass http://api;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # Timeouts
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }

        location /health {
            proxy_pass http://api;
            access_log off;
        }
    }
}

# deploy.sh
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

# ec2-setup.sh
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

# .env template
# Copy this to .env and fill in your values
NODE_ENV=production
PORT=3000
ALLOWED_ORIGINS=https://yourdomain.com,https://app.yourdomain.com

# Database settings (SQLite is file-based, no additional config needed)
DATABASE_PATH=./patient_data.db

# Security settings (optional - for JWT if you add authentication later)
# JWT_SECRET=your-super-secret-jwt-key-here
# SESSION_SECRET=your-session-secret-here

# systemd service template (patient-data-collection.service)
[Unit]
Description=Patient Data Collection API
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/patient-data-collection
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=PORT=3000

# Logging
StandardOutput=append:/var/log/patient-data-collection/access.log
StandardError=append:/var/log/patient-data-collection/error.log

[Install]
WantedBy=multi-user.target
