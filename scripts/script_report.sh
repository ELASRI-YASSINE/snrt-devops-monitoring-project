#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
# script_report.sh - fixed version
# ═══════════════════════════════════════════════════════

set -euo pipefail

PROMETHEUS_URL="http://localhost:9090"
ALERTMANAGER_URL="http://localhost:9093"
DATE=$(date "+%Y-%m-%d")
TIME=$(date "+%H:%M:%S")
REPORT_FILE="/tmp/monitoring_report_${DATE}.html"

query_prometheus() {
  curl -s --fail \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "N/A"'
}

query_avg_24h() {
  local end
  end=$(date +%s)
  local start=$(( end - 86400 ))
  curl -s --fail \
    "${PROMETHEUS_URL}/api/v1/query_range" \
    --data-urlencode "query=$1" \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode "step=300" \
    | jq -r '[.data.result[0].values[].[1] | tonumber] | add/length | . * 10 | round / 10' \
    2>/dev/null || echo "N/A"
}

# FIX 1: use awk to extract integer — avoids (( )) crash on floats like "0.0"
status_color() {
  local val
  val=$(echo "$1" | awk '{printf "%d", int($1)}')
  if   (( val >= 85 )); then echo "#e74c3c"
  elif (( val >= 70 )); then echo "#f39c12"
  else                       echo "#27ae60"
  fi
}

echo "Collecting host metrics..."

CPU_NOW_RAW=$(query_prometheus '(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100')
CPU_NOW=$(printf "%.1f" "$CPU_NOW_RAW" 2>/dev/null || echo "0.0")

MEM_NOW_RAW=$(query_prometheus '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100')
MEM_NOW=$(printf "%.1f" "$MEM_NOW_RAW" 2>/dev/null || echo "0.0")

DISK_NOW_RAW=$(query_prometheus '(1 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"})) * 100')
DISK_NOW=$(printf "%.1f" "$DISK_NOW_RAW" 2>/dev/null || echo "0.0")

MEM_TOTAL_RAW=$(query_prometheus 'node_memory_MemTotal_bytes')
MEM_TOTAL=$(echo "$MEM_TOTAL_RAW" | awk '{printf "%.1f", $1/1024/1024/1024}' 2>/dev/null || echo "N/A")

DISK_TOTAL_RAW=$(query_prometheus 'node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}')
DISK_TOTAL=$(echo "$DISK_TOTAL_RAW" | awk '{printf "%.0f", $1/1024/1024/1024}' 2>/dev/null || echo "N/A")

UPTIME_RAW=$(query_prometheus 'node_time_seconds - node_boot_time_seconds')
UPTIME=$(echo "$UPTIME_RAW" | awk '{printf "%.1f", $1/3600}' 2>/dev/null || echo "N/A")

echo "Collecting app metrics..."

APP_UP=$(query_prometheus 'up{job="nodejs-app"}')
APP_STATUS_TEXT=$([[ "$APP_UP" == "1" ]] && echo "UP" || echo "DOWN")
APP_STATUS_COLOR=$([[ "$APP_UP" == "1" ]] && echo "#27ae60" || echo "#e74c3c")

APP_REQUESTS=$(query_prometheus 'sum(http_requests_total)')
APP_REQUESTS=$(printf "%.0f" "$APP_REQUESTS" 2>/dev/null || echo "0")

APP_RPS_RAW=$(query_prometheus 'sum(rate(http_requests_total[2m]))')
APP_RPS=$(printf "%.2f" "$APP_RPS_RAW" 2>/dev/null || echo "0.00")

APP_P95_RAW=$(query_prometheus 'histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))')
APP_P95=$(echo "$APP_P95_RAW" | awk '{printf "%.0f", $1*1000}' 2>/dev/null || echo "0")

# FIX 2: Prometheus returns N/A when no 5xx requests exist yet
# explicitly replace N/A with 0 before printf to avoid "0.00.0" bug
APP_ERR_RAW=$(query_prometheus '(sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) * 100')
[[ "$APP_ERR_RAW" == "N/A" ]] && APP_ERR_RAW="0"
APP_ERR=$(printf "%.1f" "$APP_ERR_RAW" 2>/dev/null || echo "0.0")

APP_HEAP_RAW=$(query_prometheus 'app_nodejs_heap_size_used_bytes')
APP_HEAP=$(echo "$APP_HEAP_RAW" | awk '{printf "%.1f", $1/1024/1024}' 2>/dev/null || echo "N/A")

echo "Computing 24h averages..."
CPU_AVG=$(query_avg_24h '(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100')
MEM_AVG=$(query_avg_24h '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100')

echo "Fetching active alerts..."
ALERTS_JSON=$(curl -s "${ALERTMANAGER_URL}/api/v2/alerts?active=true&silenced=false" 2>/dev/null || echo "[]")
ALERTS_COUNT=$(echo "$ALERTS_JSON" | jq 'length' 2>/dev/null || echo "0")

CPU_COLOR=$(status_color "$CPU_NOW")
MEM_COLOR=$(status_color "$MEM_NOW")
DISK_COLOR=$(status_color "$DISK_NOW")
ERR_COLOR=$(status_color "$APP_ERR")

# FIX 3: build alerts HTML block BEFORE heredoc
# subshell $() inside heredoc is unreliable
if [[ "$ALERTS_COUNT" == "0" ]]; then
  ALERTS_HTML='<div class="alert-item alert-ok"><div class="dot" style="background:#27ae60"></div>No active alerts — all systems normal</div>'
else
  ALERTS_HTML=$(echo "$ALERTS_JSON" | jq -r '.[] | "\(.labels.severity)|\(.labels.alertname)|\(.annotations.summary)"' | \
    while IFS='|' read -r sev name summary; do
      cls="alert-warning"; dot_color="#f39c12"
      [[ "$sev" == "critical" ]] && cls="alert-critical" && dot_color="#e74c3c"
      echo "<div class=\"alert-item ${cls}\"><div class=\"dot\" style=\"background:${dot_color}\"></div><div><strong>${name}</strong><br>${summary}</div></div>"
    done)
fi

echo "Generating HTML report..."

cat > "$REPORT_FILE" << HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Monitoring Report — ${DATE}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f0f2f5; color: #2c3e50; padding: 2rem; line-height: 1.6; }
    .header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: white; padding: 2rem 2.5rem; border-radius: 14px; margin-bottom: 2rem; display: flex; justify-content: space-between; align-items: center; }
    .header h1 { font-size: 1.6rem; font-weight: 600; }
    .header p  { opacity: 0.6; font-size: 0.85rem; margin-top: 0.3rem; }
    .badge { background: rgba(255,255,255,0.15); padding: 0.4rem 1rem; border-radius: 20px; font-size: 0.8rem; }
    .section-title { font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 2px; color: #7f8c8d; margin: 2rem 0 1rem; }
    .grid-4 { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 1rem; }
    .grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 1rem; margin-bottom: 1rem; }
    .card { background: white; border-radius: 12px; padding: 1.5rem; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
    .card h3 { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 1px; color: #95a5a6; margin-bottom: 0.8rem; }
    .metric-value { font-size: 2.4rem; font-weight: 700; line-height: 1; }
    .metric-sub { font-size: 0.8rem; color: #95a5a6; margin-top: 0.4rem; }
    .bar-bg { background: #ecf0f1; border-radius: 6px; height: 6px; margin-top: 1rem; overflow: hidden; }
    .bar-fill { height: 100%; border-radius: 6px; }
    .info-row { display: flex; justify-content: space-between; align-items: center; padding: 0.6rem 0; border-bottom: 1px solid #f0f2f5; font-size: 0.9rem; }
    .info-row:last-child { border-bottom: none; }
    .info-label { color: #7f8c8d; }
    .info-value { font-weight: 600; }
    .alert-item { padding: 0.8rem 1rem; border-radius: 8px; margin-bottom: 0.5rem; font-size: 0.88rem; display: flex; align-items: center; gap: 0.6rem; }
    .alert-critical { background: #fdecea; border-left: 4px solid #e74c3c; }
    .alert-warning  { background: #fef9e7; border-left: 4px solid #f39c12; }
    .alert-ok       { background: #eafaf1; border-left: 4px solid #27ae60; }
    .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    footer { text-align: center; color: #95a5a6; font-size: 0.78rem; margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #ecf0f1; }
  </style>
</head>
<body>

  <div class="header">
    <div>
      <h1>Infrastructure Monitoring Report</h1>
      <p>Generated on ${DATE} at ${TIME} &nbsp;·&nbsp; ${PROMETHEUS_URL}</p>
    </div>
    <span class="badge">monitoring-infra</span>
  </div>

  <p class="section-title">Host Metrics — Linux / EC2</p>
  <div class="grid-4">
    <div class="card">
      <h3>CPU Usage</h3>
      <div class="metric-value" style="color:${CPU_COLOR}">${CPU_NOW}%</div>
      <div class="metric-sub">24h average: ${CPU_AVG}%</div>
      <div class="bar-bg"><div class="bar-fill" style="width:${CPU_NOW}%;background:${CPU_COLOR}"></div></div>
    </div>
    <div class="card">
      <h3>Memory Usage</h3>
      <div class="metric-value" style="color:${MEM_COLOR}">${MEM_NOW}%</div>
      <div class="metric-sub">Total: ${MEM_TOTAL} GB &nbsp;·&nbsp; 24h avg: ${MEM_AVG}%</div>
      <div class="bar-bg"><div class="bar-fill" style="width:${MEM_NOW}%;background:${MEM_COLOR}"></div></div>
    </div>
    <div class="card">
      <h3>Disk Usage (/)</h3>
      <div class="metric-value" style="color:${DISK_COLOR}">${DISK_NOW}%</div>
      <div class="metric-sub">Total: ${DISK_TOTAL} GB</div>
      <div class="bar-bg"><div class="bar-fill" style="width:${DISK_NOW}%;background:${DISK_COLOR}"></div></div>
    </div>
    <div class="card">
      <h3>Host Uptime</h3>
      <div class="metric-value" style="color:#2980b9">${UPTIME}</div>
      <div class="metric-sub">hours</div>
    </div>
  </div>

  <p class="section-title">Node.js App Metrics</p>
  <div class="grid-4">
    <div class="card">
      <h3>App Status</h3>
      <div class="metric-value" style="color:${APP_STATUS_COLOR}">${APP_STATUS_TEXT}</div>
      <div class="metric-sub">job: nodejs-app</div>
    </div>
    <div class="card">
      <h3>Total Requests</h3>
      <div class="metric-value" style="color:#2980b9">${APP_REQUESTS}</div>
      <div class="metric-sub">${APP_RPS} req/sec now</div>
    </div>
    <div class="card">
      <h3>p95 Response Time</h3>
      <div class="metric-value" style="color:#8e44ad">${APP_P95}</div>
      <div class="metric-sub">milliseconds</div>
    </div>
    <div class="card">
      <h3>Error Rate</h3>
      <div class="metric-value" style="color:${ERR_COLOR}">${APP_ERR}%</div>
      <div class="metric-sub">5xx responses</div>
    </div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h3>System Info</h3>
      <div class="info-row"><span class="info-label">Report date</span><span class="info-value">${DATE}</span></div>
      <div class="info-row"><span class="info-label">Generated at</span><span class="info-value">${TIME}</span></div>
      <div class="info-row"><span class="info-label">Total RAM</span><span class="info-value">${MEM_TOTAL} GB</span></div>
      <div class="info-row"><span class="info-label">Disk total</span><span class="info-value">${DISK_TOTAL} GB</span></div>
      <div class="info-row"><span class="info-label">Heap used</span><span class="info-value">${APP_HEAP} MB</span></div>
      <div class="info-row"><span class="info-label">Prometheus</span><span class="info-value">localhost:9090</span></div>
      <div class="info-row"><span class="info-label">Grafana</span><span class="info-value">localhost:3000</span></div>
      <div class="info-row"><span class="info-label">Alertmanager</span><span class="info-value">localhost:9093</span></div>
    </div>
    <div class="card">
      <h3>Active Alerts (${ALERTS_COUNT})</h3>
      ${ALERTS_HTML}
    </div>
  </div>

  <footer>
    Generated by script_report.sh &nbsp;·&nbsp;
    Stack: Prometheus + Grafana + Alertmanager + Node Exporter &nbsp;·&nbsp;
    Project: monitoring-infra
  </footer>

</body>
</html>
HTML

echo ""
echo "✓ Report saved to: ${REPORT_FILE}"
echo "  Open with: xdg-open ${REPORT_FILE}"
echo ""
