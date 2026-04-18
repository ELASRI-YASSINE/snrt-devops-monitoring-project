#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
# script_alerts.sh
# PURPOSE : Check metric thresholds locally and show
#           active alerts from Alertmanager API
# USAGE   : ./scripts/script_alerts.sh
# CRON    : */5 * * * * /path/to/script_alerts.sh >> /var/log/alerts.log 2>&1
# REQUIRES: curl, jq
# ═══════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────
PROMETHEUS_URL="http://localhost:9090"
ALERTMANAGER_URL="http://localhost:9093"
LOG_FILE="/tmp/monitoring_alerts.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# Thresholds — must match alerts.yml
CPU_WARN=80
CPU_CRIT=95
MEM_WARN=85
MEM_CRIT=95
DISK_WARN=80
DISK_CRIT=90
ERROR_RATE_WARN=10
RESPONSE_TIME_WARN=1

# ── Colors ───────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Track how many alerts fired this run
ALERT_COUNT=0

# ── Helper: query Prometheus ─────────────────────────────
query_prometheus() {
  curl -s --fail \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // "0"'
}

# ── Helper: log and print an alert ───────────────────────
fire_alert() {
  local severity="$1"
  local message="$2"
  local color="$YELLOW"
  [[ "$severity" == "CRITICAL" ]] && color="$RED"

  echo -e "    ${color}[${severity}]${NC} ${message}"
  echo "[${TIMESTAMP}] [${severity}] ${message}" >> "$LOG_FILE"
  (( ALERT_COUNT++ )) || true
}

# ── Helper: print OK ─────────────────────────────────────
print_ok() {
  local message="$1"
  echo -e "    ${GREEN}[OK]${NC} ${message}"
}

# ════════════════════════════════════════════════════════
# HEADER
# ════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              ALERT CHECK REPORT                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  ${BLUE}Timestamp :${NC} ${TIMESTAMP}"
echo ""

# ── Check Prometheus is reachable ────────────────────────
if ! curl -s --fail "${PROMETHEUS_URL}/-/healthy" > /dev/null 2>&1; then
  echo -e "${RED}  [CRITICAL] Prometheus unreachable at ${PROMETHEUS_URL}${NC}"
  echo "[${TIMESTAMP}] [CRITICAL] Prometheus unreachable" >> "$LOG_FILE"
  exit 1
fi

# ════════════════════════════════════════════════════════
# HOST CHECKS
# ════════════════════════════════════════════════════════
echo -e "${BOLD}${CYAN}  ── HOST CHECKS ─────────────────────────────────${NC}"
echo ""

# ── CPU ──────────────────────────────────────────────────
echo -e "${BOLD}  CPU:${NC}"
CPU_RAW=$(query_prometheus \
  '(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))) * 100')
CPU=$(printf "%.1f" "$CPU_RAW")
CPU_INT=${CPU%.*}

if   (( CPU_INT >= CPU_CRIT )); then
  fire_alert "CRITICAL" "CPU at ${CPU}% — exceeds critical threshold (${CPU_CRIT}%)"
elif (( CPU_INT >= CPU_WARN )); then
  fire_alert "WARNING"  "CPU at ${CPU}% — exceeds warning threshold (${CPU_WARN}%)"
else
  print_ok "CPU at ${CPU}% — normal"
fi
echo ""

# ── MEMORY ───────────────────────────────────────────────
echo -e "${BOLD}  Memory:${NC}"
MEM_RAW=$(query_prometheus \
  '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100')
MEM=$(printf "%.1f" "$MEM_RAW")
MEM_INT=${MEM%.*}

if   (( MEM_INT >= MEM_CRIT )); then
  fire_alert "CRITICAL" "Memory at ${MEM}% — exceeds critical threshold (${MEM_CRIT}%)"
elif (( MEM_INT >= MEM_WARN )); then
  fire_alert "WARNING"  "Memory at ${MEM}% — exceeds warning threshold (${MEM_WARN}%)"
else
  print_ok "Memory at ${MEM}% — normal"
fi
echo ""

# ── DISK ─────────────────────────────────────────────────
echo -e "${BOLD}  Disk (/):${NC}"
DISK_RAW=$(query_prometheus \
  '(1 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"})) * 100')
DISK=$(printf "%.1f" "$DISK_RAW")
DISK_INT=${DISK%.*}

if   (( DISK_INT >= DISK_CRIT )); then
  fire_alert "CRITICAL" "Disk at ${DISK}% — exceeds critical threshold (${DISK_CRIT}%)"
elif (( DISK_INT >= DISK_WARN )); then
  fire_alert "WARNING"  "Disk at ${DISK}% — exceeds warning threshold (${DISK_WARN}%)"
else
  print_ok "Disk at ${DISK}% — normal"
fi
echo ""

# ════════════════════════════════════════════════════════
# NODE.JS APP CHECKS
# ════════════════════════════════════════════════════════
echo -e "${BOLD}${CYAN}  ── NODE.JS APP CHECKS ──────────────────────────${NC}"
echo ""

# ── APP STATUS ───────────────────────────────────────────
echo -e "${BOLD}  App status:${NC}"
APP_UP=$(query_prometheus 'up{job="nodejs-app"}')
if [[ "$APP_UP" == "1" ]]; then
  print_ok "Node.js app is reachable"
else
  fire_alert "CRITICAL" "Node.js app is DOWN — not reachable by Prometheus"
fi
echo ""

# ── ERROR RATE ───────────────────────────────────────────
echo -e "${BOLD}  HTTP error rate:${NC}"
ERR_RAW=$(query_prometheus \
  '(sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) * 100')
# Default to 0 if no data yet
ERR_RAW=${ERR_RAW:-0}
ERR=$(printf "%.1f" "$ERR_RAW" 2>/dev/null || echo "0.0")
ERR_INT=${ERR%.*}

if   (( ERR_INT >= 30 )); then
  fire_alert "CRITICAL" "Error rate at ${ERR}% — more than 30% of requests failing"
elif (( ERR_INT >= ERROR_RATE_WARN )); then
  fire_alert "WARNING"  "Error rate at ${ERR}% — exceeds threshold (${ERROR_RATE_WARN}%)"
else
  print_ok "Error rate at ${ERR}% — normal"
fi
echo ""

# ── RESPONSE TIME ─────────────────────────────────────────
echo -e "${BOLD}  Response time (p95):${NC}"
P95_RAW=$(query_prometheus \
  'histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))')
P95=$(printf "%.2f" "$P95_RAW" 2>/dev/null || echo "0.00")
# Compare as float using awk
P95_OVER=$(echo "$P95 $RESPONSE_TIME_WARN" | \
  awk '{print ($1 > $2) ? "yes" : "no"}')

if [[ "$P95_OVER" == "yes" ]]; then
  fire_alert "WARNING" "p95 response time is ${P95}s — exceeds threshold (${RESPONSE_TIME_WARN}s)"
else
  print_ok "p95 response time is ${P95}s — normal"
fi
echo ""

# ════════════════════════════════════════════════════════
# ACTIVE ALERTS FROM ALERTMANAGER
# Shows alerts that Prometheus has already fired
# ════════════════════════════════════════════════════════
echo -e "${BOLD}${CYAN}  ── ACTIVE ALERTS FROM ALERTMANAGER ─────────────${NC}"
echo ""

ACTIVE=$(curl -s --fail \
  "${ALERTMANAGER_URL}/api/v2/alerts?active=true&silenced=false" \
  2>/dev/null || echo "[]")

ALERT_COUNT_AM=$(echo "$ACTIVE" | jq 'length' 2>/dev/null || echo "0")

if [[ "$ALERT_COUNT_AM" == "0" ]]; then
  echo -e "    ${GREEN}No active alerts in Alertmanager${NC}"
else
  echo "$ACTIVE" | jq -r '.[] | "    [\(.labels.severity | ascii_upcase)] \(.labels.alertname) — \(.annotations.summary)"' \
    | while IFS= read -r line; do
        if echo "$line" | grep -q "CRITICAL"; then
          echo -e "${RED}${line}${NC}"
        else
          echo -e "${YELLOW}${line}${NC}"
        fi
      done
fi
echo ""

# ════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════
echo -e "${BOLD}  ── SUMMARY ─────────────────────────────────────${NC}"
echo ""
if (( ALERT_COUNT == 0 )); then
  echo -e "  ${GREEN}✓ All checks passed — no threshold breaches${NC}"
else
  echo -e "  ${RED}✗ ${ALERT_COUNT} local alert(s) fired${NC}"
  echo -e "  ${BLUE}  Log file: ${LOG_FILE}${NC}"
fi
echo -e "  ${BLUE}  Alertmanager active: ${ALERT_COUNT_AM} alert(s)${NC}"
echo ""
