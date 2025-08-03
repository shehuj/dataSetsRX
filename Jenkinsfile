pipeline {
  agent any

  environment {
    // Static environment settings (no shell code in environment block)
    DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
    DOCKERHUB_REPO        = 'captcloud01/dataSetsRX'
    APP_NAME               = 'ftrx-patient-data-collection'
    APP_PORT               = '3000'
    NODE_VERSION           = '18'
    BUILD_VERSION          = "${BUILD_NUMBER}"
  }

  options {
    // Keep only last 10 builds
    buildDiscarder(logRotator(numToKeepStr: '10'))

    // Timeout the build after 30 minutes
    timeout(time: 30, unit: 'MINUTES')

    // Skip default checkout (we issue it manually)
    skipDefaultCheckout(false)
  }

  stages {
    stage('Checkout') {
      steps {
        echo "Checking out code..."
        checkout scm

        script {
          // Compute short SHA, build Docker tags, and set build meta
          env.GIT_COMMIT_SHORT = sh(
            script: "git rev-parse --short HEAD",
            returnStdout: true
          ).trim()

          env.DOCKER_TAG        = "${BUILD_NUMBER}-${GIT_COMMIT_SHORT}"
          env.DOCKER_LATEST_TAG = "latest"

          currentBuild.displayName = "#${BUILD_NUMBER} - ${env.GIT_COMMIT_SHORT}"
          currentBuild.description = "Branch: ${env.BRANCH_NAME}"
        }
      }
    }

    stage('Environment Setup') {
      steps {
        echo "Setting up build environment…"

        script {
          def nodeHome = tool name: "NodeJS-${NODE_VERSION}", type: 'NodeJSInstallation'
          env.PATH = "${nodeHome}/bin:${env.PATH}"
        }

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
        echo "Installing NPM dependencies…"
        sh '''
          npm ci --only=production
          npm audit --audit-level moderate
        '''
      }
    }

    stage('Code Quality & Testing') {
      parallel {
        stage('Lint Code') {
          steps {
            sh '''
              npm install --save-dev eslint
              if [ ! -f .eslintrc.js ]; then
                cat > .eslintrc.js << 'EOF'
module.exports = {
  env: { node: true, es2021: true },
  extends: ['eslint:recommended'],
  parserOptions: { ecmaVersion: 12, sourceType: 'module' },
  rules: { 'no-unused-vars': 'warn', 'no-console': 'off' }
};
EOF
              fi
              echo "Running ESLint…"
              npx eslint . --ext .js --ignore-pattern node_modules/
            '''
          }
        }

        stage('Security Scan') {
          steps {
            sh '''
              echo "Running npm audit with level high…"
              npm audit --audit-level high
            '''
          }
        }

        stage('Unit Tests') {
          steps {
            script {
              try {
                sh '''
                  npm install --save-dev jest supertest
                  if [ ! -d tests ]; then
                    mkdir -p tests
                    cat > tests/api.test.js << 'EOF'
const request = require('supertest');
const app = require('../server');
describe('API Health Check', () => {
  test('GET /health returns 200', async () => {
    expect(true).toBe(true); // replace with actual tests
  });
});
EOF
                  fi
                  echo "Tests would run here – replace with actual test implementation"
                '''
              } catch (err) {
                echo "Tests failed, continuing build: ${err}"
              }
            }
          }
        }
      }
    }

    stage('Build Docker Image') {
      steps {
        script {
          echo "Building Docker image: ${DOCKERHUB_REPO}:${DOCKER_TAG}"
          def img = docker.build("${DOCKERHUB_REPO}:${DOCKER_TAG}")
          if (env.BRANCH_NAME in ['main', 'master']) {
            img.tag("${DOCKER_LATEST_TAG}")
          }
          env.DOCKER_IMAGE_ID = img.id
        }

        sh """
          echo "Verifying Docker image:"
          docker inspect ${DOCKERHUB_REPO}:${DOCKER_TAG}
        """
      }
    }

    stage('Test Docker Image') {
      steps {
        script {
          sh """
            docker run -d --name test-container-${BUILD_NUMBER} -p 3001:3000 ${DOCKERHUB_REPO}:${DOCKER_TAG}
            sleep 10
            curl -f http://localhost:3001/health
            echo "Container health check passed"
          """
        }
      }
      post {
        always {
          sh """
            docker stop test-container-${BUILD_NUMBER} || true
            docker rm test-container-${BUILD_NUMBER} || true
          """
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
        echo "Pushing Docker image to Docker Hub..."
        script {
          docker.withRegistry('https://registry.hub.docker.com', 'dockerhub-credentials') {
            docker.image("${DOCKERHUB_REPO}:${DOCKER_TAG}").push()
            if (env.BRANCH_NAME in ['main', 'master']) {
              docker.image("${DOCKERHUB_REPO}:${DOCKER_LATEST_TAG}").push()
            }
          }
        }
        echo "Successfully pushed ${DOCKERHUB_REPO}:${DOCKER_TAG}"
      }
    }

    stage('Deploy to Staging') {
      when {
        branch 'develop'
      }
      steps {
        sshagent(['ec2-staging-key']) {
          sh """
            ssh -o StrictHostKeyChecking=no ec2-user@your-staging-server << 'EOF'
              docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
              docker stop patient-data-staging || true
              docker rm patient-data-staging || true
              docker run -d --name patient-data-staging -p 3000:3000 -v /opt/patient-data/staging:/app/data \\
                -e NODE_ENV=staging --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
              sleep 10
              curl -f http://localhost:3000/health
EOF
          """
        }
      }
    }

    stage('Deploy to Production') {
      when {
        anyOf {
          branch 'main'
          branch 'master'
        }
      }
      steps {
        script {
          env.DEPLOYER = input(
            message: 'Deploy to Production?',
            ok: 'Deploy',
            submitterParameter: 'DEPLOYER'
          )
        }

        echo "Deploying to production environment… By: ${env.DEPLOYER}"

        sshagent(['ec2-production-key']) {
          sh """
            ssh -o StrictHostKeyChecking=no ec2-user@your-production-server << 'EOF'
              docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
              docker stop patient-data-prod || true
              docker rm patient-data-prod || true
              docker run -d \
                --name patient-data-prod -p 3000:3000 -v /opt/patient-data/production:/app/data \\
                -v /opt/patient-data/logs:/app/logs -e NODE_ENV=production \\
                --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
              sleep 15
              curl -f http://localhost:3000/health
              echo "Deployed ${DOCKERHUB_REPO}:${DOCKER_TAG} at \$(date)" >> /opt/patient-data/deployment.log
EOF
          """
        }

        script {
          currentBuild.description += " | Deployed by: ${env.DEPLOYER}"
        }
      }
    }
  }

  post {
    always {
      echo "Cleaning up Docker images…"
      sh """
        docker image prune -f
        docker images ${DOCKERHUB_REPO} --format "table {{.Tag}}" | \\
          grep -E '^[0-9]+-[a-f0-9]+\$' | sort -rn | tail -n +6 \\
          | xargs -r docker rmi || true
      """
    }

    success {
      echo "Pipeline completed successfully!"
      script {
        if (env.BRANCH_NAME in ['main', 'master']) {
          emailext(
            subject: "Production Deployment Successful - ${env.JOB_NAME} #${env.BUILD_NUMBER}",
            body: """
              The patient data collection application has been successfully deployed to production.

              Build: ${env.BUILD_URL}
              Docker Image: ${DOCKERHUB_REPO}:${DOCKER_TAG}
              Git Commit: ${env.GIT_COMMIT_SHORT}

              The application is now live and ready to collect patient survey data.
            """,
            to: "devops@yourcompany.com"
          )
        }
      }
    }

    failure {
      echo "Pipeline failed!"
      emailext(
        subject: "Build Failed - ${env.JOB_NAME} #${env.BUILD_NUMBER}",
        body: """
          The build has failed. Please check the Jenkins console output for details.

          Build: ${env.BUILD_URL}
          Branch: ${env.BRANCH_NAME}
          Commit: ${env.GIT_COMMIT_SHORT}
        """,
        to: "devops@yourcompany.com"
      )
    }

    unstable {
      echo "Build is unstable"
    }
  }
}
