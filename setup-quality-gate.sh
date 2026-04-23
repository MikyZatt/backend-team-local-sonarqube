#!/usr/bin/env bash
# setup-quality-gate.sh
# Configures the Backend Team Quality Gate on SonarQube.
# Idempotent: skips setup if already done (flag file in /setup volume).
set -euo pipefail

SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_USER="${SONAR_USER:-admin}"
SONAR_PASSWORD="${SONAR_PASSWORD:-admin}"
QG_NAME="Backend Team QG"
FLAG_FILE="/setup/quality_gate_configured"

# Install curl if running inside the python:slim container used by docker-compose
if ! command -v curl &>/dev/null; then
  apt-get update -qq && apt-get install -y -qq curl
fi

if [[ -f "$FLAG_FILE" ]]; then
  echo "[setup] Quality Gate already configured. Skipping."
  exit 0
fi

echo "[setup] Waiting for SonarQube to be ready at $SONAR_URL ..."
for i in $(seq 1 60); do
  STATUS=$(curl -sf "${SONAR_URL}/api/system/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [[ "$STATUS" == "UP" ]]; then
    echo "[setup] SonarQube is UP."
    break
  fi
  echo "[setup] Attempt $i/60 — status: '${STATUS}'. Retrying in 5s..."
  sleep 5
done

if [[ "$STATUS" != "UP" ]]; then
  echo "[setup] ERROR: SonarQube did not become ready in time." >&2
  exit 1
fi

AUTH="-u ${SONAR_USER}:${SONAR_PASSWORD}"

# -----------------------------------------------------------------------
# Change default admin password if still "admin" (SonarQube 9+ forces it)
# -----------------------------------------------------------------------
echo "[setup] Ensuring admin credentials are set..."
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/users/change_password" \
  -d "login=admin&previousPassword=admin&password=admin" \
  >/dev/null 2>&1 || true

# -----------------------------------------------------------------------
# Set instance name
# -----------------------------------------------------------------------
echo "[setup] Setting server name..."
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/settings/set" \
  -d "key=sonar.core.serverName&value=Backend%20Team%20local%20SonarQube" \
  >/dev/null

# -----------------------------------------------------------------------
# Create Quality Gate
# -----------------------------------------------------------------------
echo "[setup] Creating Quality Gate '${QG_NAME}'..."

# Delete existing QG with the same name if present (idempotency)
EXISTING_ID=$(curl -sf $AUTH \
  "${SONAR_URL}/api/qualitygates/list" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for qg in data.get('qualitygates', []):
    if qg['name'] == '${QG_NAME}':
        print(qg['id'])
        break
" 2>/dev/null || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo "[setup] Found existing QG id=${EXISTING_ID}, deleting..."
  curl -sf $AUTH -X POST \
    "${SONAR_URL}/api/qualitygates/destroy" \
    -d "id=${EXISTING_ID}" >/dev/null
fi

QG_ID=$(curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create" \
  -d "name=${QG_NAME// /%20}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "[setup] Created Quality Gate id=${QG_ID}"

# Issues <= 10 → fail if > 10
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=violations&op=GT&error=10" \
  >/dev/null
echo "[setup]   + condition: violations GT 10 (Issues <= 10)"

# Security Hotspots Reviewed = 100%  → fail if < 100
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=security_hotspots_reviewed&op=LT&error=100" \
  >/dev/null
echo "[setup]   + condition: security_hotspots_reviewed LT 100 (= 100%)"

# Coverage >= 80% → fail if < 80
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=coverage&op=LT&error=80" \
  >/dev/null
echo "[setup]   + condition: coverage LT 80 (>= 80%)"

# Duplicated Lines % <= 15% → fail if > 15
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=duplicated_lines_density&op=GT&error=15" \
  >/dev/null
echo "[setup]   + condition: duplicated_lines_density GT 15 (<= 15%)"

# Maintainability Rating <= A (1) → fail if > 1
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=sqale_rating&op=GT&error=1" \
  >/dev/null
echo "[setup]   + condition: sqale_rating GT 1 (Maintainability <= A)"

# Reliability Rating <= C (3) → fail if > 3
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=reliability_rating&op=GT&error=3" \
  >/dev/null
echo "[setup]   + condition: reliability_rating GT 3 (Reliability <= C)"

# Security Rating <= C (3) → fail if > 3
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create_condition" \
  -d "gateId=${QG_ID}&metric=security_rating&op=GT&error=3" \
  >/dev/null
echo "[setup]   + condition: security_rating GT 3 (Security <= C)"

# -----------------------------------------------------------------------
# Set as default Quality Gate
# -----------------------------------------------------------------------
echo "[setup] Setting '${QG_NAME}' as default Quality Gate..."
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/set_as_default" \
  -d "id=${QG_ID}" \
  >/dev/null

# -----------------------------------------------------------------------
# Mark as done
# -----------------------------------------------------------------------
mkdir -p /setup
echo "${QG_ID}" > "$FLAG_FILE"
echo "[setup] Done. Quality Gate configured successfully."
