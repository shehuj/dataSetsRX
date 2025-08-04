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

  tools {
    nodejs 'NodeJS-18'  // Ensure this matches the tool name in Jenkins configuration
  }

  stages {
    stage('Checkout & Versioning') {
      steps {
        script {
          echo '🔄 Checking out source…'
          checkout scm

          env.GIT_COMMIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.DOCKER_TAG = "${env.BUILD_VERSION}-${env.GIT_COMMIT_SHORT}"
          currentBuild.displayName = "#${env.BUILD_VERSION} – ${env.GIT_COMMIT_SHORT}"
          currentBuild.description = "Branch: ${env.BRANCH_NAME ?: 'unknown'}"
        }
      }
    }

    stage('Environment Inspection') {
      steps {
        echo '🧪 Node & Docker version info…'
        sh '''
          node --version
          npm --version
          docker --version
        '''
      }
    }

    stage('Install & Audit') {
      steps {
        echo '📦 Installing prod dependencies…'
        sh '''
          set -euxo pipefail
          export CI=true

          if [ -f package-lock.json ]; then
            npm ci --only=production
          else
            npm install --only=production
          fi
        '''

        echo '🔍 npm audit (threshold: moderate, warnings only)'
        script {
          def auditResult = sh(
            script: 'npm audit --audit-level=moderate', 
            returnStatus: true
          )
          if (auditResult != 0) {
            echo "[WARN] npm audit found vulnerabilities"
            currentBuild.result = 'UNSTABLE'
          }
        }
      }
    }

    stage('Lint & Tests') {
      parallel {
        stage('ESLint') {
          steps {
            echo '🔍 ESLint check…'
            sh '''
              npm install --no-save eslint || true
              npx eslint . --ext .js --ignore-pattern node_modules/
            '''
          }
        }
        stage('Unit Tests') {
          steps {
            echo '🧪 Tests & Coverage…'
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
          }
        }
      }
    }

    stage('Docker Build') {
      steps {
        echo '🐳 Building Docker image…'
        script {
          docker.build("${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}")
          if (env.BRANCH_NAME in ['main', 'master']) {
            docker.build("${env.DOCKERHUB_REPO}:${env.DOCKER_LATEST_TAG}")
          }
        }
      }
    }

    stage('Smoke Test Container') {
      steps {
        echo '🧪 Running container smoke test…'
        script {
          def containerName = "test-${env.BUILD_VERSION}"
          try {
            sh """
              docker run -d --name ${containerName} -p 3001:3000 ${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}
              sleep 5
              curl -f http://localhost:3001/health
            """
          } finally {
            sh """
              docker stop ${containerName} || true
              docker rm ${containerName} || true
            """
          }
        }
      }
    }

    stage('Push Image') {
      when { 
        anyOf { 
          branch 'main'
          branch 'master'
          branch 'develop' 
        } 
      }
      steps {
        echo '🚀 Pushing to Docker Hub…'
        script {
          docker.withRegistry('https://registry.hub.docker.com', 'dockerhub-credentials') {
            def image = docker.image("${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}")
            image.push()

            if (env.BRANCH_NAME in ['main', 'master']) {
              def latestImage = docker.image("${env.DOCKERHUB_REPO}:${env.DOCKER_LATEST_TAG}")
              latestImage.push()
            }
          }
        }
      }
    }

    stage('Deploy to Staging') {
      when { branch 'develop' }
      steps {
        echo '🚀 Deploying to staging…'
        sshagent(['ec2-staging-key']) {
          sh '''
            ssh -o StrictHostKeyChecking=no ec2-user@your-staging-server << 'ENDSSH'
              docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
              docker stop patient-data-staging || true
              docker rm patient-data-staging || true
              docker run -d --name patient-data-staging -p 3000:3000 \
                -v /opt/patient-data/staging:/app/data \
                -e NODE_ENV=staging --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
              sleep 10
              curl -f http://localhost:3000/health
            ENDSSH
          '''
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
        echo '🚀 Deploying to production…'
        sshagent(['ec2-production-key']) {
          sh '''
            ssh -o StrictHostKeyChecking=no ec2-user@your-production-server << 'ENDSSH'
              docker pull ${DOCKERHUB_REPO}:${DOCKER_TAG}
              docker stop patient-data-prod || true
              docker rm patient-data-prod || true
              docker run -d \
                --name patient-data-prod \
                -p 3000:3000 \
                -v /opt/patient-data/production:/app/data \
                -v /opt/patient-data/logs:/app/logs \
                -e NODE_ENV=production \
                --restart unless-stopped ${DOCKERHUB_REPO}:${DOCKER_TAG}
              sleep 15
              curl -f http://localhost:3000/health
              mkdir -p /opt/patient-data
              echo "Deployed ${DOCKERHUB_REPO}:${DOCKER_TAG} at $(date)" >> /opt/patient-data/deployment.log
            ENDSSH
          '''
        }
        script {
          currentBuild.description += " | Deployed by: ${env.DEPLOYER ?: 'unknown'}"
        }
      }
    }
  }

  post {
    always {
      script {
        // Only perform cleanup if on a build agent
        if (env.NODE_NAME != null) {
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
    success  { echo "✅ Build succeeded (${env.BRANCH_NAME})" }
    unstable { echo "⚠️ Build marked UNSTABLE" }
    failure  { echo "❌ Build FAILED — please review logs" }
    aborted  { echo "🛑 Build aborted by user" }
  }
}
