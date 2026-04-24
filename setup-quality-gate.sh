#!/usr/bin/env bash
# setup-quality-gate.sh
# Configures the Backend Team Quality Gate on SonarQube.
# Idempotent: skips setup if already done (flag file in /setup volume).
#
# Compatible with SonarQube 26.x:
# - Quality gates are identified by name (not numeric id, changed in SonarQube 10.x+)
# - SonarQube 26.x generates a random initial admin password; this script resets it to
#   "admin" via a direct PostgreSQL update so that the team can use admin:admin
set -euo pipefail

SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_USER="${SONAR_USER:-admin}"
SONAR_PASSWORD="${SONAR_PASSWORD:-admin}"
QG_NAME="Backend Team QG"
FLAG_FILE="/setup/quality_gate_configured"

# -----------------------------------------------------------------------
# Install dependencies (curl + postgresql-client) if needed
# -----------------------------------------------------------------------
if ! command -v curl &>/dev/null || ! command -v psql &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq curl postgresql-client
fi

if [[ -f "$FLAG_FILE" ]]; then
  echo "[setup] Quality Gate already configured. Skipping."
  exit 0
fi

# -----------------------------------------------------------------------
# Wait for SonarQube to be ready
# -----------------------------------------------------------------------
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

# -----------------------------------------------------------------------
# Reset admin password to "admin" via PostgreSQL.
#
# SonarQube 26.x generates a random initial admin password and stores a
# random PBKDF2 hash. The DefaultAdminCredentialsVerifierFilter blocks all
# API calls when it detects the built-in default hash. Replacing the hash
# with a freshly generated one for the same string "admin" makes the filter
# treat it as a user-set password and stops blocking API calls.
# -----------------------------------------------------------------------
echo "[setup] Resetting admin password to 'admin' via PostgreSQL..."

python3 - <<'PYEOF'
import hashlib, os, base64, subprocess, sys

password = "admin"
salt_bytes = os.urandom(20)
salt_b64   = base64.b64encode(salt_bytes).decode()
dk         = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt_bytes, 100000)
hash_b64   = base64.b64encode(dk).decode()
crypted    = f"100000${hash_b64}"

sql = f"""
UPDATE users SET
  crypted_password = '{crypted}',
  salt             = '{salt_b64}',
  hash_method      = 'PBKDF2',
  reset_password   = false
WHERE login = 'admin';
"""

result = subprocess.run(
    ["psql", "-v", "ON_ERROR_STOP=1", "-c", sql],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(f"[setup] ERROR updating admin password:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)
print("[setup] Admin password hash updated successfully.")
PYEOF

# -----------------------------------------------------------------------
# Verify authentication works
# -----------------------------------------------------------------------
echo "[setup] Verifying authentication..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${SONAR_USER}:${SONAR_PASSWORD}" \
  "${SONAR_URL}/api/qualitygates/list")
if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "[setup] ERROR: Authentication failed (HTTP ${HTTP_STATUS}). Check SONAR_USER/SONAR_PASSWORD." >&2
  exit 1
fi

AUTH="-u ${SONAR_USER}:${SONAR_PASSWORD}"

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
# NOTE: SonarQube 10.x+ uses name (not numeric id) to identify quality gates.
# -----------------------------------------------------------------------
echo "[setup] Creating Quality Gate '${QG_NAME}'..."

# Delete existing QG with the same name if present (idempotency)
EXISTING=$(curl -sf $AUTH \
  "${SONAR_URL}/api/qualitygates/list" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for qg in data.get('qualitygates', []):
    if qg['name'] == '${QG_NAME}':
        print('found')
        break
" 2>/dev/null || true)

if [[ "$EXISTING" == "found" ]]; then
  echo "[setup] Found existing QG '${QG_NAME}', deleting..."
  curl -sf $AUTH -X POST \
    "${SONAR_URL}/api/qualitygates/destroy" \
    -d "name=${QG_NAME// /+}" >/dev/null
fi

QG_NAME_RESP=$(curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/create" \
  -d "name=${QG_NAME// /+}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")

echo "[setup] Created Quality Gate: '${QG_NAME_RESP}'"

# Helper: add a condition using gateName (SonarQube 10.x+ API)
add_condition() {
  local metric="$1" op="$2" error="$3" desc="$4"
  curl -sf $AUTH -X POST \
    "${SONAR_URL}/api/qualitygates/create_condition" \
    -d "gateName=${QG_NAME// /+}&metric=${metric}&op=${op}&error=${error}" \
    >/dev/null
  echo "[setup]   + condition: ${metric} ${op} ${error}  (${desc})"
}

add_condition "violations"                 "GT" "10"  "Issues <= 10"
add_condition "security_hotspots_reviewed" "LT" "100" "Security Hotspots Reviewed = 100%"
add_condition "coverage"                   "LT" "80"  "Coverage >= 80%"
add_condition "duplicated_lines_density"   "GT" "15"  "Duplicated Lines <= 15%"
add_condition "sqale_rating"               "GT" "1"   "Maintainability Rating <= A"
add_condition "reliability_rating"         "GT" "3"   "Reliability Rating <= C"
add_condition "security_rating"            "GT" "3"   "Security Rating <= C"

# -----------------------------------------------------------------------
# Set as default Quality Gate
# -----------------------------------------------------------------------
echo "[setup] Setting '${QG_NAME}' as default Quality Gate..."
curl -sf $AUTH -X POST \
  "${SONAR_URL}/api/qualitygates/set_as_default" \
  -d "name=${QG_NAME// /+}" \
  >/dev/null

# -----------------------------------------------------------------------
# Mark as done
# -----------------------------------------------------------------------
mkdir -p /setup
echo "${QG_NAME}" > "$FLAG_FILE"
echo "[setup] Done. Quality Gate '${QG_NAME}' configured and set as default."
