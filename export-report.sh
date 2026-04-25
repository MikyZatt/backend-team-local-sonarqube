#!/usr/bin/env bash
# export-report.sh
# Exports a SAST HTML report from SonarQube and opens it in the browser.
#
# Usage:
#   ./export-report.sh --project-key <key>
#   ./export-report.sh --project-key <key> --output /path/to/report.html
#   ./export-report.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from the repository root if present (variables already set in the
# environment take precedence, so existing shell exports are not overridden).
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
  set +o allexport
fi

SONAR_PORT="${SONAR_PORT:-9000}"
SONAR_URL="${SONAR_URL:-http://localhost:${SONAR_PORT}}"
SONAR_USER="${SONAR_USER:-admin}"
SONAR_PASSWORD="${SONAR_PASSWORD:-admin}"
PROJECT_KEY=""
OUTPUT_FILE=""
OPEN_BROWSER=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[report]${NC} $*"; }
success() { echo -e "${GREEN}[report]${NC} $*"; }
warn()    { echo -e "${YELLOW}[report]${NC} $*"; }
error()   { echo -e "${RED}[report]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --project-key <key> [options]

Options:
  --project-key <key>    SonarQube project key (required)
  --output <file>        Output HTML file path (default: ./<key>-sast-report-<date>.html)
  --sonar-url <url>      SonarQube URL (default: http://localhost:9000)
  --no-browser           Do not open the browser automatically
  --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-key)  PROJECT_KEY="$2";   shift 2 ;;
    --output)       OUTPUT_FILE="$2";   shift 2 ;;
    --sonar-url)    SONAR_URL="$2";     shift 2 ;;
    --no-browser)   OPEN_BROWSER=false; shift ;;
    --help|-h)      usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$PROJECT_KEY" ]]; then
  error "--project-key is required."
  usage
fi

if [[ -z "$OUTPUT_FILE" ]]; then
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_FILE="${PROJECT_KEY}-sast-report-${TIMESTAMP}.html"
fi

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
  error "SonarQube not reachable at ${SONAR_URL}."
  exit 1
fi

AUTH="-u ${SONAR_USER}:${SONAR_PASSWORD}"
info "Fetching data for project: ${PROJECT_KEY}"

# -----------------------------------------------------------------------
# Fetch project data from SonarQube API
# -----------------------------------------------------------------------
METRICS="bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,\
ncloc,violations,security_hotspots,security_hotspots_reviewed,\
sqale_rating,reliability_rating,security_rating,sqale_index,\
alert_status,quality_gate_details"

MEASURES_JSON=$(curl -sf $AUTH \
  "${SONAR_URL}/api/measures/component?component=${PROJECT_KEY}&metricKeys=${METRICS}")

QG_JSON=$(curl -sf $AUTH \
  "${SONAR_URL}/api/qualitygates/project_status?projectKey=${PROJECT_KEY}")

PROJECT_JSON=$(curl -sf $AUTH \
  "${SONAR_URL}/api/projects/search?projects=${PROJECT_KEY}&ps=1")

# -----------------------------------------------------------------------
# Generate HTML report with Python
# -----------------------------------------------------------------------
python3 - <<PYEOF
import json, sys, datetime, os

measures_raw   = json.loads('''${MEASURES_JSON}''')
qg_raw         = json.loads('''${QG_JSON}''')
project_raw    = json.loads('''${PROJECT_JSON}''')
project_key    = '${PROJECT_KEY}'
sonar_url      = '${SONAR_URL}'
output_file    = '${OUTPUT_FILE}'

# ---------- parse measures ----------
def get_measure(measures, key):
    for m in measures:
        if m['metric'] == key:
            return m.get('value', m.get('periods', [{}])[0].get('value', 'N/A') if m.get('periods') else 'N/A')
    return 'N/A'

measures = measures_raw.get('component', {}).get('measures', [])

def mv(key): return get_measure(measures, key)

bugs             = mv('bugs')
vulnerabilities  = mv('vulnerabilities')
code_smells      = mv('code_smells')
coverage_raw     = mv('coverage')
duplication_raw  = mv('duplicated_lines_density')
violations       = mv('violations')
hotspots         = mv('security_hotspots')
hotspots_rev     = mv('security_hotspots_reviewed')
ncloc            = mv('ncloc')
sqale_idx        = mv('sqale_index')

def rating_label(v):
    try:
        r = int(float(v))
        return ['A','B','C','D','E'][r-1]
    except:
        return str(v)

def rating_color(v):
    try:
        r = int(float(v))
        return ['#00aa00','#88cc00','#ffaa00','#ff6600','#dd0000'][r-1]
    except:
        return '#888'

maint_r   = mv('sqale_rating')
rel_r     = mv('reliability_rating')
sec_r     = mv('security_rating')

maint_label  = rating_label(maint_r)
rel_label    = rating_label(rel_r)
sec_label    = rating_label(sec_r)
maint_color  = rating_color(maint_r)
rel_color    = rating_color(rel_r)
sec_color    = rating_color(sec_r)

# ---------- Quality Gate status ----------
qg_status = qg_raw.get('projectStatus', {}).get('status', 'UNKNOWN')
qg_conditions = qg_raw.get('projectStatus', {}).get('conditions', [])

def cov_fmt(v):
    try:
        return f'{float(v):.1f}%'
    except:
        return str(v)

def dup_fmt(v):
    try:
        return f'{float(v):.1f}%'
    except:
        return str(v)

# Project display name
project_name = project_key
if project_raw.get('components'):
    project_name = project_raw['components'][0].get('name', project_key)

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')

# ---------- condition table rows ----------
METRIC_LABELS = {
    'violations':                     'Total Issues',
    'security_hotspots_reviewed':     'Security Hotspots Reviewed',
    'coverage':                       'Code Coverage',
    'duplicated_lines_density':       'Duplicated Lines',
    'sqale_rating':                   'Maintainability Rating',
    'reliability_rating':             'Reliability Rating',
    'security_rating':                'Security Rating',
    'new_violations':                 'New Issues',
    'new_coverage':                   'New Coverage',
    'new_duplicated_lines_density':   'New Duplicated Lines',
    'new_security_hotspots_reviewed': 'New Hotspots Reviewed',
}

def op_label(op, error):
    if op == 'GT':   return f'≤ {error}'
    if op == 'LT':   return f'≥ {error}'
    if op == 'EQ':   return f'= {error}'
    if op == 'NE':   return f'≠ {error}'
    return f'{op} {error}'

condition_rows = ''
for c in qg_conditions:
    metric    = c.get('metricKey', '')
    status    = c.get('status', '')
    actual    = c.get('actualValue', 'N/A')
    error     = c.get('errorThreshold', '')
    op        = c.get('comparator', '')
    label     = METRIC_LABELS.get(metric, metric)
    threshold = op_label(op, error)
    if status == 'OK':
        row_class = 'cond-ok'
        badge = '<span class="badge badge-ok">OK</span>'
    elif status == 'ERROR':
        row_class = 'cond-fail'
        badge = '<span class="badge badge-fail">FAIL</span>'
    else:
        row_class = ''
        badge = f'<span class="badge">{status}</span>'

    # Format actual value for rating metrics
    if metric in ('sqale_rating','reliability_rating','security_rating'):
        try:
            actual_display = rating_label(actual)
        except:
            actual_display = actual
    elif metric in ('coverage','duplicated_lines_density','security_hotspots_reviewed',
                    'new_coverage','new_duplicated_lines_density','new_security_hotspots_reviewed'):
        actual_display = cov_fmt(actual)
    else:
        actual_display = actual

    condition_rows += f'''
        <tr class="{row_class}">
          <td>{label}</td>
          <td class="center">{threshold}</td>
          <td class="center">{actual_display}</td>
          <td class="center">{badge}</td>
        </tr>'''

# ---------- banner color ----------
if qg_status == 'OK':
    qg_color = '#00aa00'
    qg_text  = 'PASSED'
    qg_icon  = '&#10003;'
elif qg_status == 'ERROR':
    qg_color = '#dd0000'
    qg_text  = 'FAILED'
    qg_icon  = '&#10007;'
else:
    qg_color = '#888'
    qg_text  = qg_status
    qg_icon  = '&#8212;'

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SAST Report — {project_name}</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           background: #f5f6fa; color: #333; }}
    .header {{ background: #1e2a38; color: white; padding: 32px 48px; }}
    .header h1 {{ font-size: 22px; font-weight: 600; opacity: .7; margin-bottom: 4px; }}
    .header h2 {{ font-size: 32px; font-weight: 700; }}
    .header .meta {{ margin-top: 8px; font-size: 13px; opacity: .6; }}
    .qg-banner {{ padding: 24px 48px; display: flex; align-items: center;
                  gap: 16px; background: {qg_color}; color: white; }}
    .qg-banner .icon {{ font-size: 48px; line-height: 1; }}
    .qg-banner .label {{ font-size: 14px; text-transform: uppercase; letter-spacing: 1px; opacity: .85; }}
    .qg-banner .status {{ font-size: 36px; font-weight: 800; }}
    .container {{ max-width: 1000px; margin: 32px auto; padding: 0 24px; }}
    h3 {{ font-size: 18px; font-weight: 600; margin-bottom: 16px; color: #1e2a38; }}
    .metrics-grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
                     gap: 16px; margin-bottom: 32px; }}
    .metric-card {{ background: white; border-radius: 8px; padding: 20px 16px;
                    box-shadow: 0 1px 4px rgba(0,0,0,.1); text-align: center; }}
    .metric-card .value {{ font-size: 32px; font-weight: 700; color: #1e2a38; }}
    .metric-card .title {{ font-size: 12px; color: #888; margin-top: 4px; text-transform: uppercase; letter-spacing: .5px; }}
    .ratings {{ display: flex; gap: 16px; margin-bottom: 32px; flex-wrap: wrap; }}
    .rating-card {{ background: white; border-radius: 8px; padding: 20px 24px;
                    box-shadow: 0 1px 4px rgba(0,0,0,.1); text-align: center; flex: 1; min-width: 140px; }}
    .rating-letter {{ font-size: 48px; font-weight: 900; }}
    .rating-title {{ font-size: 12px; color: #888; margin-top: 4px; text-transform: uppercase; letter-spacing: .5px; }}
    table {{ width: 100%; border-collapse: collapse; background: white;
             border-radius: 8px; overflow: hidden;
             box-shadow: 0 1px 4px rgba(0,0,0,.1); margin-bottom: 32px; }}
    th {{ background: #1e2a38; color: white; padding: 12px 16px;
          text-align: left; font-size: 13px; font-weight: 600; }}
    td {{ padding: 12px 16px; border-bottom: 1px solid #f0f0f0; font-size: 14px; }}
    tr:last-child td {{ border-bottom: none; }}
    .center {{ text-align: center; }}
    .cond-ok  td {{ background: #f0fff4; }}
    .cond-fail td {{ background: #fff5f5; }}
    .badge {{ display: inline-block; padding: 3px 10px; border-radius: 12px;
              font-size: 12px; font-weight: 700; }}
    .badge-ok   {{ background: #c6f6d5; color: #276749; }}
    .badge-fail {{ background: #fed7d7; color: #9b2c2c; }}
    .footer {{ text-align: center; font-size: 12px; color: #aaa; padding: 24px; }}
    a {{ color: #3182ce; }}
  </style>
</head>
<body>

<div class="header">
  <h1>Backend Team local SonarQube — SAST Report</h1>
  <h2>{project_name}</h2>
  <div class="meta">Generated on {now} &nbsp;|&nbsp; Project: <code>{project_key}</code></div>
</div>

<div class="qg-banner">
  <div class="icon">{qg_icon}</div>
  <div>
    <div class="label">Quality Gate</div>
    <div class="status">{qg_text}</div>
  </div>
</div>

<div class="container">

  <h3>Key Metrics</h3>
  <div class="metrics-grid">
    <div class="metric-card">
      <div class="value">{bugs}</div>
      <div class="title">Bugs</div>
    </div>
    <div class="metric-card">
      <div class="value">{vulnerabilities}</div>
      <div class="title">Vulnerabilities</div>
    </div>
    <div class="metric-card">
      <div class="value">{code_smells}</div>
      <div class="title">Code Smells</div>
    </div>
    <div class="metric-card">
      <div class="value">{violations}</div>
      <div class="title">Total Issues</div>
    </div>
    <div class="metric-card">
      <div class="value">{cov_fmt(coverage_raw)}</div>
      <div class="title">Coverage</div>
    </div>
    <div class="metric-card">
      <div class="value">{dup_fmt(duplication_raw)}</div>
      <div class="title">Duplication</div>
    </div>
    <div class="metric-card">
      <div class="value">{hotspots}</div>
      <div class="title">Security Hotspots</div>
    </div>
    <div class="metric-card">
      <div class="value">{cov_fmt(hotspots_rev)}</div>
      <div class="title">Hotspots Reviewed</div>
    </div>
    <div class="metric-card">
      <div class="value">{ncloc}</div>
      <div class="title">Lines of Code</div>
    </div>
  </div>

  <h3>Ratings</h3>
  <div class="ratings">
    <div class="rating-card">
      <div class="rating-letter" style="color:{maint_color}">{maint_label}</div>
      <div class="rating-title">Maintainability</div>
    </div>
    <div class="rating-card">
      <div class="rating-letter" style="color:{rel_color}">{rel_label}</div>
      <div class="rating-title">Reliability</div>
    </div>
    <div class="rating-card">
      <div class="rating-letter" style="color:{sec_color}">{sec_label}</div>
      <div class="rating-title">Security</div>
    </div>
  </div>

  <h3>Quality Gate Conditions Detail</h3>
  <table>
    <thead>
      <tr>
        <th>Metric</th>
        <th class="center">Team Threshold</th>
        <th class="center">Actual Value</th>
        <th class="center">Status</th>
      </tr>
    </thead>
    <tbody>
      {condition_rows}
    </tbody>
  </table>

  <p style="font-size:13px;color:#666;">
    Full analysis available at
    <a href="{sonar_url}/dashboard?id={project_key}" target="_blank">
      {sonar_url}/dashboard?id={project_key}
    </a>
  </p>

</div>

<div class="footer">Backend Team local SonarQube &mdash; {now}</div>
</body>
</html>"""

with open(output_file, 'w', encoding='utf-8') as f:
    f.write(html)

print(output_file)
PYEOF

OUTPUT_PATH="$OUTPUT_FILE"

success "Report generated: ${OUTPUT_PATH}"

if [[ "$OPEN_BROWSER" == "true" ]]; then
  info "Opening in browser..."
  if command -v xdg-open &>/dev/null; then
    xdg-open "$(realpath "$OUTPUT_PATH")" &
  elif command -v open &>/dev/null; then
    open "$(realpath "$OUTPUT_PATH")"
  else
    warn "Cannot open browser automatically. Open manually: $(realpath "$OUTPUT_PATH")"
  fi
fi
