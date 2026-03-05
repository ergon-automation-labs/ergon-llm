pipeline {
  // Phase 1: Run on built-in controller
  // Phase 2: Will switch to dedicated 'air-local' agent with proper plugin setup
  agent { label 'built-in' }

  options {
    timeout(time: 60, unit: 'MINUTES')
    timestamps()
  }

  environment {
    MIX_ENV = 'prod'
    BOT_NAME = 'llm_proxy'
    RELEASE_DIR = "/opt/ergon/releases/${BOT_NAME}"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        sh '''
          echo "Cloning dependency repositories..."
          cd ..
          [ -d bot_army_core ] || git clone https://github.com/ergon-automation-labs/ergon-core.git bot_army_core
          [ -d bot_army_runtime ] || git clone https://github.com/ergon-automation-labs/ergon-runtime.git bot_army_runtime
        '''
      }
    }

    stage('Restore Cache') {
      steps {
        script {
          try {
            echo "Checking for cached dependencies from previous build..."
            unstash 'deps-cache'
            sh '''
              echo "Extracting deps cache..."
              tar -xzf deps-cache.tar.gz 2>/dev/null || echo "Cache extraction failed or not present"
              rm -f deps-cache.tar.gz
            '''
          } catch (Exception e) {
            echo "No deps cache found (first build is expected to be slow)"
          }

          try {
            unstash 'build-cache'
            sh '''
              echo "Extracting build cache..."
              tar -xzf build-cache.tar.gz 2>/dev/null || echo "Build cache extraction failed or not present"
              rm -f build-cache.tar.gz
            '''
          } catch (Exception e) {
            echo "No build cache found"
          }
        }
      }
    }

    stage('Test') {
      steps {
        sh '''
          echo "Installing dependencies..."
          mix deps.get
          echo "Running tests..."
          mix test
        '''
      }
    }

    stage('Build Release') {
      steps {
        sh '''
          echo "Building OTP release..."
          mix deps.get --only prod
          mix release --overwrite
        '''
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          DEST="${RELEASE_DIR}/releases/${TIMESTAMP}"

          echo "Creating release directory..."
          mkdir -p "${DEST}"

          echo "Copying release artifacts..."
          cp -r _build/prod/rel/${BOT_NAME}/* "${DEST}/"

          echo "Updating current symlink..."
          ln -sfn "${DEST}" "${RELEASE_DIR}/current"

          echo "Restarting service..."
          launchctl kickstart -k system/com.botarmy.${BOT_NAME} || launchctl load /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist

          echo "Waiting for service to stabilize..."
          sleep 5

          echo "Deploy complete!"
        '''
      }
    }

  }

  post {
    success {
      sh '''
        echo "Caching dependencies for next build..."
        tar -czf deps-cache.tar.gz deps/ 2>/dev/null || echo "No deps to cache"
        tar -czf build-cache.tar.gz _build/ 2>/dev/null || echo "No build to cache"
      '''
      script {
        try {
          stash name: 'deps-cache', includes: 'deps-cache.tar.gz', allowEmpty: true
        } catch (Exception e) {
          echo "Failed to stash deps cache: ${e.message}"
        }

        try {
          stash name: 'build-cache', includes: 'build-cache.tar.gz', allowEmpty: true
        } catch (Exception e) {
          echo "Failed to stash build cache: ${e.message}"
        }
      }
      sh '''
        VERSION=$(cat _build/prod/rel/${BOT_NAME}/releases/RELEASES | tail -1 | cut -d' ' -f2)
        /opt/bot_army/scripts/nats_publish.sh ops.deploy.complete \
          "{\"bot\":\"${BOT_NAME}\",\"node\":\"air\",\"triggered_by\":\"jenkins\",\"status\":\"success\",\"version\":\"${VERSION}\"}"
      '''
    }
    failure {
      sh '''
        /opt/bot_army/scripts/nats_publish.sh ops.deploy.failed \
          "{\"bot\":\"${BOT_NAME}\",\"node\":\"air\",\"triggered_by\":\"jenkins\",\"status\":\"failed\"}"
      '''
    }
  }
}
