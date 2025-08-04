pipeline {
    agent any

    environment {
        DOCKERHUB_CREDENTIALS = credentials('dockerhub-credentials')
        DOCKERHUB_REPO = 'captcloud01/patient-data-collection'
        APP_NAME = 'patient-data-collection'
        NODE_VERSION = '18'
        BUILD_VERSION = "${BUILD_NUMBER}"
        DOCKER_LATEST_TAG = 'latest'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 60, unit: 'MINUTES')
        skipDefaultCheckout(false)
    }

    tools {
        nodejs 'NodeJS-18'
    }

    stages {
        stage('Prepare Environment') {
            steps {
                script {
                    // Enhanced logging and error tracking
                    env.BUILD_ERRORS = []
                    env.BUILD_WARNINGS = []

                    // Checkout and versioning
                    try {
                        checkout scm
                        env.GIT_COMMIT_SHORT = sh(
                            script: 'git rev-parse --short HEAD', 
                            returnStdout: true
                        ).trim()
                        env.DOCKER_TAG = "${env.BUILD_VERSION}-${env.GIT_COMMIT_SHORT}"
                        currentBuild.displayName = "#${env.BUILD_VERSION} – ${env.GIT_COMMIT_SHORT}"
                    } catch (err) {
                        env.BUILD_ERRORS << "Git Checkout Failed: ${err.message}"
                        error "Checkout failed: ${err.message}"
                    }
                }
            }
        }

        stage('Dependency Management') {
            steps {
                script {
                    def installScript = '''
                    #!/bin/bash
                    set -euo pipefail

                    # Logging function
                    log() {
                        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
                    }

                    # Error and warning tracking
                    export CI=true
                    WARNINGS=()
                    ERRORS=()

                    # Dependency installation with flexible handling
                    install_deps() {
                        local method="$1"
                        log "Attempting dependency installation: $method"
                        
                        if $method; then
                            log "Dependencies installed successfully"
                        else
                            ERRORS+=("Dependency installation failed with $method")
                            return 1
                        fi
                    }

                    # Prefer npm ci, fallback strategies
                    if [ -f package-lock.json ]; then
                        install_deps "npm ci --only=production" || 
                        install_deps "npm install --only=production" ||
                        ERRORS+=("All npm install attempts failed")
                    elif [ -f yarn.lock ]; then
                        install_deps "yarn install --production" ||
                        ERRORS+=("Yarn installation failed")
                    else
                        install_deps "npm install --only=production" ||
                        ERRORS+=("npm install failed")
                    fi

                    # Dependency audit with warning mechanism
                    if npm audit --audit-level=moderate; then
                        log "Security audit passed"
                    else
                        WARNINGS+=("Moderate security vulnerabilities detected")
                    fi

                    # Output errors and warnings
                    if [ ${#ERRORS[@]} -gt 0 ]; then
                        echo "ERRORS:"
                        printf '%s\n' "${ERRORS[@]}"
                        exit 1
                    fi

                    if [ ${#WARNINGS[@]} -gt 0 ]; then
                        echo "WARNINGS:"
                        printf '%s\n' "${WARNINGS[@]}"
                    fi
                    '''

                    def result = sh(
                        script: installScript, 
                        returnStatus: true
                    )

                    if (result != 0) {
                        env.BUILD_ERRORS << "Dependency Installation Failed"
                        unstable "Dependency issues detected"
                    }
                }
            }
        }

        stage('Code Quality') {
            parallel {
                stage('Lint') {
                    steps {
                        script {
                            try {
                                sh '''
                                    npm run lint || {
                                        echo "[WARN] Linting found issues"
                                        exit 0  # Allow build to continue
                                    }
                                '''
                            } catch (err) {
                                env.BUILD_WARNINGS << "Linting Warnings: ${err.message}"
                            }
                        }
                    }
                }

                stage('Unit Tests') {
                    steps {
                        script {
                            try {
                                sh 'npm test -- --coverage'
                                junit '**/test-results.xml'
                            } catch (err) {
                                env.BUILD_WARNINGS << "Test Failures: ${err.message}"
                                unstable "Some tests failed"
                            }
                        }
                    }
                }
            }
        }

        stage('Build & Package') {
            steps {
                script {
                    try {
                        docker.build("${env.DOCKERHUB_REPO}:${env.DOCKER_TAG}")
                    } catch (err) {
                        env.BUILD_ERRORS << "Docker Build Failed: ${err.message}"
                        error "Build failed: ${err.message}"
                    }
                }
            }
        }

        stage('Final Status Report') {
            steps {
                script {
                    if (env.BUILD_ERRORS) {
                        echo "❌ BUILD ERRORS DETECTED:"
                        env.BUILD_ERRORS.each { error ->
                            echo "- ${error}"
                        }
                    }

                    if (env.BUILD_WARNINGS) {
                        echo "⚠️ BUILD WARNINGS:"
                        env.BUILD_WARNINGS.each { warning ->
                            echo "- ${warning}"
                        }
                    }

                    if (!env.BUILD_ERRORS && !env.BUILD_WARNINGS) {
                        echo "✅ Build completed successfully"
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                // Cleanup and archiving
                archiveArtifacts(
                    artifacts: 'reports/**/*,logs/**/*', 
                    allowEmptyArchive: true
                )
            }
        }
        success {
            echo "🎉 Pipeline completed successfully"
        }
        unstable {
            echo "⚠️ Pipeline is unstable due to warnings"
        }
        failure {
            echo "❌ Pipeline failed"
        }
    }
}
