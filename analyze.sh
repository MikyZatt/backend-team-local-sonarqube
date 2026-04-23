#!/usr/bin/env bash
# analyze.sh
# Analyzes a project with SonarQube.
#
# Usage:
#   ./analyze.sh                         # auto-detect project type
#   ./analyze.sh --type maven            # force Maven
#   ./analyze.sh --type gradle           # force Gradle
#   ./analyze.sh --type typescript       # force TypeScript/Node
#   ./analyze.sh --project-key my-app    # specify project key
#   ./analyze.sh --help
#
# Run this script from the root of the project you want to analyze.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"

SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_USER="${SONAR_USER:-admin}"
SONAR_PASSWORD="${SONAR_PASSWORD:-admin}"
PROJECT_KEY=""
PROJECT_TYPE=""
SONAR_TOKEN=""

# -----------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[analyze]${NC} $*"; }
success() { echo -e "${GREEN}[analyze]${NC} $*"; }
warn()    { echo -e "${YELLOW}[analyze]${NC} $*"; }
error()   { echo -e "${RED}[analyze]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --type <maven|gradle|typescript>   Project type (default: auto-detect)
  --project-key <key>                SonarQube project key (default: directory name)
  --sonar-url <url>                  SonarQube URL (default: http://localhost:9000)
  --help                             Show this help

Environment variables:
  SONAR_URL       SonarQube instance URL
  SONAR_USER      Username (default: admin)
  SONAR_PASSWORD  Password (default: admin)
EOF
  exit 0
}

# -----------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)         PROJECT_TYPE="$2"; shift 2 ;;
    --project-key)  PROJECT_KEY="$2";  shift 2 ;;
    --sonar-url)    SONAR_URL="$2";    shift 2 ;;
    --help|-h)      usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

# -----------------------------------------------------------------------
# Auto-detect project type
# -----------------------------------------------------------------------
detect_project_type() {
  if [[ -f "$PROJECT_DIR/pom.xml" ]]; then
    echo "maven"
  elif [[ -f "$PROJECT_DIR/build.gradle" || -f "$PROJECT_DIR/build.gradle.kts" ]]; then
    echo "gradle"
  elif [[ -f "$PROJECT_DIR/package.json" ]]; then
    echo "typescript"
  else
    echo ""
  fi
}

if [[ -z "$PROJECT_TYPE" ]]; then
  PROJECT_TYPE="$(detect_project_type)"
  if [[ -z "$PROJECT_TYPE" ]]; then
    error "Cannot detect project type. Use --type <maven|gradle|typescript>."
    exit 1
  fi
  info "Detected project type: ${PROJECT_TYPE}"
fi

# -----------------------------------------------------------------------
# Default project key = directory name
# -----------------------------------------------------------------------
if [[ -z "$PROJECT_KEY" ]]; then
  PROJECT_KEY="$(basename "$PROJECT_DIR")"
  # Sanitize: replace invalid characters with hyphens
  PROJECT_KEY="${PROJECT_KEY//[^a-zA-Z0-9_\-.]/-}"
fi

info "Project key: ${PROJECT_KEY}"
info "Directory:   ${PROJECT_DIR}"
info "SonarQube:   ${SONAR_URL}"

# -----------------------------------------------------------------------
# Check SonarQube is reachable
# -----------------------------------------------------------------------
check_sonar() {
  local status
  status=$(curl -sf "${SONAR_URL}/api/system/status" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  [[ "$status" == "UP" ]]
}

if ! check_sonar; then
  error "SonarQube not reachable at ${SONAR_URL}. Start it with: docker compose up -d"
  exit 1
fi

# -----------------------------------------------------------------------
# Get or create an analysis token
# -----------------------------------------------------------------------
get_or_create_token() {
  local token_name="analyze-${PROJECT_KEY}"
  # Revoke any previous token with the same name (ignore errors)
  curl -sf -u "${SONAR_USER}:${SONAR_PASSWORD}" -X POST \
    "${SONAR_URL}/api/user_tokens/revoke" \
    -d "name=${token_name}" >/dev/null 2>&1 || true

  SONAR_TOKEN=$(curl -sf -u "${SONAR_USER}:${SONAR_PASSWORD}" -X POST \
    "${SONAR_URL}/api/user_tokens/generate" \
    -d "name=${token_name}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
}

info "Generating analysis token..."
get_or_create_token

# -----------------------------------------------------------------------
# Coverage collection functions
# -----------------------------------------------------------------------
run_maven_coverage() {
  info "Running tests and collecting coverage with Maven..."
  if ! mvn -q verify -Pcoverage 2>/dev/null; then
    warn "Profile 'coverage' not found, running: mvn verify"
    mvn verify || warn "Tests failed, continuing with analysis..."
  fi
}

run_gradle_coverage() {
  info "Running tests and collecting coverage with Gradle..."
  local gradle_cmd="./gradlew"
  [[ ! -f "$gradle_cmd" ]] && gradle_cmd="gradle"
  $gradle_cmd test jacocoTestReport || warn "Tests failed or JaCoCo not configured, continuing..."
}

run_typescript_coverage() {
  info "Running tests and collecting coverage with Jest..."
  if [[ ! -d "node_modules" ]]; then
    info "Installing npm dependencies..."
    npm install
  fi
  # Check for a test script in package.json
  if python3 -c "import json,sys; s=json.load(open('package.json')); exit(0 if 'test' in s.get('scripts',{}) else 1)" 2>/dev/null; then
    npm test -- --coverage --watchAll=false 2>/dev/null || \
      npx jest --coverage --watchAll=false 2>/dev/null || \
      warn "Tests failed or Jest not configured, continuing without coverage..."
  else
    warn "No 'test' script found in package.json, continuing without coverage..."
  fi
}

# -----------------------------------------------------------------------
# Analysis by project type
# -----------------------------------------------------------------------
case "$PROJECT_TYPE" in
  maven)
    command -v mvn >/dev/null 2>&1 || { error "mvn not found. Install Java JDK 17+ and Maven."; exit 1; }
    run_maven_coverage
    info "Starting SonarQube analysis with Maven..."
    mvn sonar:sonar \
      -Dsonar.projectKey="${PROJECT_KEY}" \
      -Dsonar.host.url="${SONAR_URL}" \
      -Dsonar.token="${SONAR_TOKEN}" \
      -Dsonar.projectName="${PROJECT_KEY}"
    ;;

  gradle)
    run_gradle_coverage
    info "Starting SonarQube analysis with Gradle..."
    local_gradle="./gradlew"
    [[ ! -f "$local_gradle" ]] && local_gradle="gradle"
    $local_gradle sonarqube \
      -Dsonar.projectKey="${PROJECT_KEY}" \
      -Dsonar.host.url="${SONAR_URL}" \
      -Dsonar.token="${SONAR_TOKEN}" \
      -Dsonar.projectName="${PROJECT_KEY}"
    ;;

  typescript)
    command -v node >/dev/null 2>&1 || { error "node not found. Install Node.js 18+."; exit 1; }
    command -v npx  >/dev/null 2>&1 || { error "npx not found. Update Node.js."; exit 1; }
    run_typescript_coverage
    info "Starting SonarQube analysis with sonar-scanner..."
    # Use local or global sonar-scanner
    if ! command -v sonar-scanner &>/dev/null; then
      info "sonar-scanner not found globally, falling back to npx..."
      SCANNER_CMD="npx sonar-scanner"
    else
      SCANNER_CMD="sonar-scanner"
    fi
    # Look for LCOV coverage report
    LCOV_OPTS=""
    if [[ -f "coverage/lcov.info" ]]; then
      LCOV_OPTS="-Dsonar.javascript.lcov.reportPaths=coverage/lcov.info"
    fi
    $SCANNER_CMD \
      -Dsonar.projectKey="${PROJECT_KEY}" \
      -Dsonar.projectName="${PROJECT_KEY}" \
      -Dsonar.host.url="${SONAR_URL}" \
      -Dsonar.token="${SONAR_TOKEN}" \
      -Dsonar.sources=src \
      -Dsonar.exclusions="**/*.test.ts,**/*.spec.ts,**/node_modules/**" \
      ${LCOV_OPTS}
    ;;

  *)
    error "Unsupported project type: ${PROJECT_TYPE}. Use: maven, gradle, typescript"
    exit 1
    ;;
esac

# -----------------------------------------------------------------------
# Wait for the analysis task to complete
# -----------------------------------------------------------------------
info "Analysis submitted. Waiting for SonarQube to process it..."
sleep 5

# Poll task status
for i in $(seq 1 20); do
  TASK_STATUS=$(curl -sf -u "${SONAR_USER}:${SONAR_PASSWORD}" \
    "${SONAR_URL}/api/ce/component?component=${PROJECT_KEY}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = data.get('queue', []) + ([data['current']] if 'current' in data else [])
if tasks:
    print(tasks[0].get('status', 'UNKNOWN'))
else:
    print('NO_TASK')
" 2>/dev/null || echo "UNKNOWN")

  case "$TASK_STATUS" in
    SUCCESS)
      success "Analysis completed successfully!"
      break
      ;;
    FAILED|CANCELLED)
      error "Analysis task ended with status: ${TASK_STATUS}"
      exit 1
      ;;
    IN_PROGRESS|PENDING)
      info "Task in progress (attempt $i/20)..."
      sleep 5
      ;;
    NO_TASK|UNKNOWN)
      warn "Task status unavailable, may already be complete."
      break
      ;;
  esac
done

# -----------------------------------------------------------------------
# Display Quality Gate result
# -----------------------------------------------------------------------
QG_STATUS=$(curl -sf -u "${SONAR_USER}:${SONAR_PASSWORD}" \
  "${SONAR_URL}/api/qualitygates/project_status?projectKey=${PROJECT_KEY}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['projectStatus']['status'])" 2>/dev/null || echo "UNKNOWN")

echo ""
if [[ "$QG_STATUS" == "OK" ]]; then
  success "Quality Gate: PASSED ✓"
elif [[ "$QG_STATUS" == "ERROR" ]]; then
  warn "Quality Gate: FAILED ✗"
else
  info "Quality Gate: ${QG_STATUS}"
fi

echo ""
info "Results available at: ${SONAR_URL}/dashboard?id=${PROJECT_KEY}"
info "To export the SAST report run:"
echo "  ${SCRIPT_DIR}/export-report.sh --project-key ${PROJECT_KEY}"
