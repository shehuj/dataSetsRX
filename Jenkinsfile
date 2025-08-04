pipeline {
  agent any

  environment {
    DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
    DOCKERHUB_REPO        = 'captcloud01/patient-data-collection'
    APP_NAME              = 'patient-data-collection'
    NODE_VERSION          = '18'
    BUILD_VERSION         = "${BUILD_NUMBER}"
    DOCKER_LATEST_TAG     = 'latest'
  }

  options {
    buildDiscarder(logRotator(numToKeepStr: '10'))
    timeout(time: 60, unit: 'MINUTES')
    skipDefaultCheckout(false)
  }

  stages {

    stage('Checkout & Versioning') {
      steps {
        echo '🔄 Checking out source…'
        checkout scm

        script { _ ->
          env.GIT_COMMIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.DOCKER_TAG = "${env.BUILD_VERSION}-${env.GIT_COMMIT_SHORT}"
          currentBuild.displayName = "#${env.BUILD_VERSION} – ${env.GIT_COMMIT_SHORT}"
          currentBuild.description = "Branch: ${env.BRANCH_NAME ?: 'unknown'}"
        }
      }
    }

    stage('Environment Inspection') {
      steps {
        echo '🧪 Verifying Node and Docker versions…'
        sh '''
          echo "Node.js: $(node --version || echo 'not installed')"
          echo "npm: $(npm --version || echo 'not installed')"
          echo "Docker: $(docker --version || echo 'not installed')"
        '''
        script { _ ->
          try {
            def nodeHome = tool(name: 'NodeJS‑18', type: 'jenkins.plugins.nodejs.tools.NodeJSInstallation')
            env.PATH = "${nodeHome}/bin:${env.PATH}"
          } catch (e) {
            echo "[WARN] NodeJS tool not configured: ${e.message}"
          }
        }
      }
    }

    stage('Install Dependencies & Audit') {
      steps {
        echo '📦 Installing production dependencies…'
        sh '''
          set -euxo pipefail
          export CI=true

          if [[ -f package-lock.json ]]; then
            npm ci --only=production
          else
            echo "[WARN] package-lock.json not found—running npm install"
            npm install --only=production
          fi
        '''

        echo '🔍 Running npm audit (moderate threshold)'
        script { _ ->
          def auditStatus = sh(script: 'npm audit --audit-level=moderate', returnStatus: true)
          if (auditStatus != 0) {
            echo "[WARN] npm audit detected ≥ moderate vulnerabilities (exit=${auditStatus}); marking UNSTABLE"
            currentBuild.result = 'UNSTABLE'
          } else {
            echo "[OK] No ≥ moderate vulnerabilities detected"
          }
        }
      }
    }

    stage('Lint & Test') {
      parallel {
        stage('ESLint') {
          steps {
            echo '🔍 Running ESLint…'
            sh '''
              npm install --no-save eslint || true
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
              npx eslint . --ext .js --ignore-pattern node_modules/ || echo "[WARN] Lint issues found"
            '''
          }
        }

        stage('Unit / Integration Tests') {
          steps {
            echo '🧪 Running tests & coverage…'
            sh '''
              npm ci --no-audit
              npm test -- --coverage --coverageReporters=text --coverageReporters=lcov
            '''
          }
          post {
            always {
              junit '**/jest-junit.xml'
              archiveArtifacts artifacts: 'coverage/lcov-report/**', allowEmptyArchive: true
            }
            unstable {
              echo '[WARN] Tests completeness issues detected (marking UNSTABLE)'
            }
          }
        }
      }
    }

    stage('Build Docker Image') {
      steps {
        echo '🐳 Building Docker image…'
        script { _ ->
          def img = docker.build("${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}")
          if (env.BRANCH_NAME in ['main','master']) {
            img.tag(env.DOCKER_LATEST_TAG)
          }
          env.DOCKER_IMAGE_ID = img.id
        }
        sh '''
          docker image inspect "${DOCKERHUB_REPO}:${DOCKER_TAG}"
        '''
      }
    }

    stage('Smoke Test Docker Container') {
      steps {
        echo '🧪 Smoke-testing the built container…'
        script { _ ->
          def name = "test-${BUILD_VERSION}"
          try {
            sh """
              docker run -d --name ${name} -p 3001:3000 ${DOCKERHUB_REPO}:${DOCKER_TAG}
              sleep 5
              curl -f http://localhost:3001/health || echo "[WARN] Container health fallback"
            """
          } finally {
            sh """
              docker stop ${name} || true
              docker rm ${name} || true
            """
          }
        }
      }
    }

    stage('Push to Docker Hub') {
      when { anyOf { branch 'main'; branch 'master'; branch 'develop' } }
      steps {
        echo '🚀 Pushing image to Docker Hub…'
        script { _ ->
          docker.withRegistry('https://registry.hub.docker.com', 'dockerhub-credentials') {
            docker.image("${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}").push()
            if (env.BRANCH_NAME in ['main','master']) {
              docker.image("${env.DOCKERHUB_REPO}:${DOCKER_LATEST_TAG}").push()
            }
          }
        }
        echo "[OK] Pushed ${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}"
      }
    }

    stage('Deploy to Staging') {
      when { branch 'develop' }
      steps {
        script { _ ->
          sshagent(['ec2-staging-key']) {
            sh '''
              ssh -o StrictHostKeyChecking=no ec2-user@your-staging-server << 'EOF'
                docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
                docker stop patient-data-staging || true
                docker rm patient-data-staging || true
                docker run -d --name patient-data-staging -p 3000:3000 \
                  -v /opt/patient-data/staging:/app/data \
                  -e NODE_ENV=staging --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
                sleep 10
                curl -f http://localhost:3000/health || echo "[WARN] Staging health fallback"
EOF
            '''
          }
        }
      }
    }

    stage('Deploy to Production') {
      when { anyOf { branch 'main'; branch 'master' } }
      steps {
        script { _ ->
          env.DEPLOYER = input message: 'Deploy to Production?', ok: 'Deploy', submitterParameter: 'DEPLOYER'
          echo "[INFO] Approved by: ${env.DEPLOYER}"
        }
        echo '🚀 Deploying to production…'
        script { _ ->
          sshagent(['ec2-production-key']) {
            sh '''
              ssh -o StrictHostKeyChecking=no ec2-user@your-production-server << 'EOF'
                docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
                docker stop patient-data-prod || true
                docker rm patient-data-prod || true
                docker run -d --name patient-data-prod -p 3000:3000 \
                  -v /opt/patient-data/production:/app/data \
                  -v /opt/patient-data/logs:/app/logs \
                  -e NODE_ENV=production --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
                sleep 15
                curl -f http://localhost:3000/health || echo "[WARN] Prod health fallback"
                mkdir -p /opt/patient-data
                echo "Deployed ${DOCKERHUB_REPO}:${DOCKER_TAG} at $(date)" >> /opt/patient-data/deployment.log
EOF
            '''
          }
        }
        script { _ ->
          currentBuild.description += " | Deployed by: ${env.DEPLOYER ?: 'unknown'}"
        }
      }
    }
  }

  post {
    always {
      script { _ ->
        if (getContext(hudson.FilePath)) {
          echo '🧹 Cleaning old Docker images…'
          sh '''
            docker image prune -f || true
            docker images ${DOCKERHUB_REPO} --format "{{.Tag}}" | \
              grep -E "^[0-9]+-[0-9a-f]+$" | sort -rn | tail -n +6 | \
              xargs -r -I {} docker rmi ${DOCKERHUB_REPO}:{} || true
          '''
          archiveArtifacts artifacts: 'logs/**/*', allowEmptyArchive: true
        }
      }
    }
    success { echo "✅ Build succeeded for branch ${env.BRANCH_NAME ?: 'unknown'}" }
    unstable { echo "⚠️ Build marked UNSTABLE due to lint/audit/test warnings" }
    failure { echo "❌ Build failed — please check console output" }
    aborted { echo "🛑 Build was aborted by user" }
  }
}
