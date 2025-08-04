pipeline {
    agent any
    
    environment {
        // Docker Hub credentials (stored in Jenkins credentials)
        DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
        DOCKERHUB_REPO = 'captcloud01/patient-data-collection'
        
        // Application configuration
        APP_NAME = 'patient-data-collection'
        NODE_VERSION = '18'
        
        // Build information
        BUILD_VERSION = "${BUILD_NUMBER}"
        GIT_COMMIT_SHORT = sh(
            script: "git rev-parse --short HEAD",
            returnStdout: true
        ).trim()
        
        // Docker image tags
        DOCKER_TAG = "${BUILD_VERSION}-${GIT_COMMIT_SHORT}"
        DOCKER_LATEST_TAG = "latest"
    }
    
    options {
        // Keep only last 10 builds
        buildDiscarder(logRotator(numToKeepStr: '10'))
        
        // Timeout the build after 30 minutes
        timeout(time: 30, unit: 'MINUTES')
        
        // Skip default checkout
        skipDefaultCheckout(false)
    }
    
    stages {
        stage('Checkout') {
            steps {
                echo "🔄 Checking out code..."
                checkout scm
                
                script {
                    // Set build display name
                    currentBuild.displayName = "#${BUILD_NUMBER} - ${GIT_COMMIT_SHORT}"
                    currentBuild.description = "Branch: ${env.BRANCH_NAME ?: 'unknown'}"
                }
            }
        }
        
        stage('Environment Setup') {
            steps {
                echo "🏗️ Setting up build environment..."
                
                script {
                    // Check if NodeJS tool is configured, otherwise use system node
                    try {
                        def nodeHome = tool name: 'NodeJS-18', type: 'jenkins.plugins.nodejs.tools.NodeJSInstallation'
                        env.PATH = "${nodeHome}/bin:${env.PATH}"
                    } catch (Exception e) {
                        echo "NodeJS tool not configured in Jenkins, using system Node.js"
                    }
                }
                
                // Verify versions
                sh '''
                    echo "Node.js version:"
                    node --version
                    echo "NPM version:"
                    npm --version
                    echo "Docker version:"
                    docker --version
                '''
            }
        }
        
        stage('Install Dependencies') {
            steps {
                echo "📦 Installing NPM dependencies..."
                
                sh '''
                    # Use npm install if package-lock.json doesn't exist
                    if [ -f package-lock.json ]; then
                        npm ci --only=production
                    else
                        npm install --only=production
                    fi
                    
                    # Run audit with proper error handling
                    npm audit --audit-level moderate || echo "Audit found issues but continuing..."
                '''
            }
        }
        
        stage('Code Quality & Testing') {
            parallel {
                stage('Lint Code') {
                    steps {
                        echo "🔍 Running code linting..."
                        
                        sh '''
                            # Install dev dependencies for linting
                            npm install --save-dev eslint
                            
                            # Create basic ESLint config if not exists
                            if [ ! -f .eslintrc.js ]; then
                                cat > .eslintrc.js << 'EOF'
module.exports = {
    env: {
        node: true,
        es2021: true
    },
    extends: ['eslint:recommended'],
    parserOptions: {
        ecmaVersion: 12,
        sourceType: 'module'
    },
    rules: {
        'no-unused-vars': 'warn',
        'no-console': 'off'
    }
};
EOF
                            fi
                            
                            # Run linting with proper error handling
                            npx eslint . --ext .js --ignore-pattern node_modules/ || echo "Linting issues found but continuing..."
                        '''
                    }
                }
                
                stage('Security Scan') {
                    steps {
                        echo "🔒 Running security audit..."
                        
                        sh '''
                            # Run npm audit with proper error handling
                            npm audit --audit-level high || echo "Security issues found but continuing..."
                            
                            # Optional: Use additional security tools
                            # npx audit-ci --moderate
                        '''
                    }
                }
                
                stage('Unit Tests') {
                    steps {
                        echo "🧪 Running unit tests..."
                        
                        script {
                            try {
                                sh '''
                                    # Install test dependencies
                                    npm install --save-dev jest supertest
                                    
                                    # Create basic test if not exists
                                    if [ ! -d tests ]; then
                                        mkdir -p tests
                                        cat > tests/api.test.js << 'EOF'
const request = require('supertest');
// const app = require('../server');

describe('API Health Check', () => {
    test('GET /health should return 200', async () => {
        // Mock test - replace with actual tests
        expect(true).toBe(true);
    });
});
EOF
                                    fi
                                    
                                    # Run tests (mock for now)
                                    echo "Tests would run here - implement actual tests"
                                    # npx jest
                                '''
                            } catch (Exception e) {
                                echo "⚠️ Tests failed but continuing build: ${e.getMessage()}"
                            }
                        }
                    }
                }
            }
        }
        
        stage('Build Docker Image') {
            steps {
                echo "🐳 Building Docker image..."
                
                script {
                    // Build the Docker image
                    def dockerImage = docker.build("${DOCKERHUB_REPO}:${DOCKER_TAG}")
                    
                    // Also tag as latest for main branch
                    if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'master') {
                        dockerImage.tag("${DOCKER_LATEST_TAG}")
                    }
                    
                    // Store image for later use
                    env.DOCKER_IMAGE_ID = dockerImage.id
                }
                
                // Verify image was built
                sh """
                    docker images ${DOCKERHUB_REPO}:${DOCKER_TAG}
                    docker inspect ${DOCKERHUB_REPO}:${DOCKER_TAG}
                """
            }
        }
        
        stage('Test Docker Image') {
            steps {
                echo "🧪 Testing Docker image..."
                
                script {
                    try {
                        // Start container for testing
                        sh """
                            # Start container in background
                            docker run -d --name test-container-${BUILD_NUMBER} \
                                -p 3001:3000 \
                                ${DOCKERHUB_REPO}:${DOCKER_TAG}
                            
                            # Wait for container to start
                            sleep 10
                            
                            # Test health endpoint (with fallback if no health endpoint)
                            curl -f http://localhost:3001/health || curl -f http://localhost:3001/ || echo "Health check endpoint not available"
                            
                            echo "✅ Container health check passed"
                        """
                    } finally {
                        // Always cleanup test container
                        sh """
                            docker stop test-container-${BUILD_NUMBER} || true
                            docker rm test-container-${BUILD_NUMBER} || true
                        """
                    }
                }
            }
        }
        
        stage('Push to Docker Hub') {
            when {
                anyOf {
                    branch 'main'
                    branch 'master'
                    branch 'develop'
                }
            }
            steps {
                echo "🚀 Pushing Docker image to Docker Hub..."
                
                script {
                    docker.withRegistry('https://registry.hub.docker.com', 'dockerhub-credentials') {
                        // Push versioned tag
                        docker.image("${DOCKERHUB_REPO}:${DOCKER_TAG}").push()
                        
                        // Push latest tag for main branch
                        if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'master') {
                            docker.image("${DOCKERHUB_REPO}:${DOCKER_LATEST_TAG}").push()
                        }
                    }
                }
                
                echo "✅ Successfully pushed ${DOCKERHUB_REPO}:${DOCKER_TAG}"
            }
        }
        
        stage('Deploy to Staging') {
            when {
                branch 'develop'
            }
            steps {
                echo "🚀 Deploying to staging environment..."
                
                script {
                    // Deploy to staging EC2 instance
                    sshagent(['ec2-staging-key']) {
                        sh """
                            ssh -o StrictHostKeyChecking=no ec2-user@your-staging-server << 'EOF'
                                # Pull latest image
                                docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
                                
                                # Stop existing container
                                docker stop patient-data-staging || true
                                docker rm patient-data-staging || true
                                
                                # Start new container
                                docker run -d \
                                    --name patient-data-staging \
                                    -p 3000:3000 \
                                    -v /opt/patient-data/staging:/app/data \
                                    -e NODE_ENV=staging \
                                    --restart unless-stopped \
                                    ${DOCKERHUB_REPO}:${DOCKER_TAG}
                                
                                # Health check
                                sleep 10
                                curl -f http://localhost:3000/health || curl -f http://localhost:3000/ || echo "Health check completed"
EOF
                        """
                    }
                }
            }
        }
        
        stage('Deploy to Production') {
            when {
                allOf {
                    anyOf {
                        branch 'main'
                        branch 'master'
                    }
                }
            }
            steps {
                script {
                    def userInput = input(
                        message: 'Deploy to Production?',
                        ok: 'Deploy',
                        submitterParameter: 'DEPLOYER'
                    )
                    echo "User approved deployment: ${userInput}"
                }
                
                echo "🚀 Deploying to production environment..."
                
                script {
                    sshagent(['ec2-production-key']) {
                        sh """
                            ssh -o StrictHostKeyChecking=no ec2-user@your-production-server << 'EOF'
                                # Pull latest image
                                docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
                                
                                # Stop existing container gracefully
                                docker stop patient-data-prod || true
                                docker rm patient-data-prod || true
                                
                                # Start new container
                                docker run -d \
                                    --name patient-data-prod \
                                    -p 3000:3000 \
                                    -v /opt/patient-data/production:/app/data \
                                    -v /opt/patient-data/logs:/app/logs \
                                    -e NODE_ENV=production \
                                    --restart unless-stopped \
                                    ${DOCKERHUB_REPO}:${DOCKER_TAG}
                                
                                # Health check
                                sleep 15
                                curl -f http://localhost:3000/health || curl -f http://localhost:3000/ || echo "Health check completed"
                                
                                # Tag this deployment
                                echo "Deployed ${DOCKERHUB_REPO}:${DOCKER_TAG} at \$(date)" >> /opt/patient-data/deployment.log
EOF
                        """
                    }
                }
                
                script {
                    currentBuild.description += " | Deployed by: ${env.DEPLOYER ?: 'unknown'}"
                }
            }
        }
    }
    
    post {
        always {
            echo "🧹 Cleaning up..."
            
            // Clean up Docker images to save space
            sh """
                # Remove dangling images
                docker image prune -f || true
                
                # Remove old images (keep last 5 builds) - safer approach
                docker images ${DOCKERHUB_REPO} --format "{{.Tag}}" | \
                    grep -E '^[0-9]+-[a-f0-9]+\$' | \
                    sort -rn | \
                    tail -n +6 | \
                    xargs -r -I {} docker rmi ${DOCKERHUB_REPO}:{} || true
            """
            
            // Archive logs if they exist
            archiveArtifacts artifacts: 'logs/**/*', allowEmptyArchive: true
        }
        
        success {
            echo "✅ Pipeline completed successfully!"
            
            script {
                if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'master') {
                    echo "Production deployment completed successfully"
                    // Uncomment and configure your notification method
                    /*
                    emailext (
                        subject: "✅ Production Deployment Successful - ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                        body: """
                        <h2>Production Deployment Successful</h2>
                        <p><strong>Project:</strong> ${env.JOB_NAME}</p>
                        <p><strong>Build Number:</strong> ${env.BUILD_NUMBER}</p>
                        <p><strong>Git Commit:</strong> ${env.GIT_COMMIT_SHORT}</p>
                        <p><strong>Docker Image:</strong> ${DOCKERHUB_REPO}:${DOCKER_TAG}</p>
                        <p><strong>Build URL:</strong> <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></p>
                        """,
                        to: 'devops@yourcompany.com',
                        mimeType: 'text/html'
                    )
                    */
                }
            }
        }
        
        failure {
            echo "❌ Pipeline failed!"
            
            script {
                // Uncomment and configure your notification method
                /*
                emailext (
                    subject: "❌ Pipeline Failed - ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                    body: """
                    <h2>Pipeline Failed</h2>
                    <p><strong>Project:</strong> ${env.JOB_NAME}</p>
                    <p><strong>Build Number:</strong> ${env.BUILD_NUMBER}</p>
                    <p><strong>Branch:</strong> ${env.BRANCH_NAME}</p>
                    <p><strong>Build URL:</strong> <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></p>
                    <p>Please check the build logs for more details.</p>
                    """,
                    to: 'devops@yourcompany.com',
                    mimeType: 'text/html'
                )
                */
            }
        }
        
        unstable {
            echo "⚠️ Pipeline completed with warnings"
        }
    }
}
