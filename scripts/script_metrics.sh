#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
# script_metrics.sh
# PURPOSE : Query Prometheus API and display live metrics
#           for both the host (EC2) and the Node.js app
# USAGE   : ./scripts/script_metrics.sh
# REQUIRES: curl, jq
# ═══════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ────────────────────────────────────────
PROMETHEUS_URL="http://localhost:9090"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# ── Colors ───────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helper: query Prometheus instant API ─────────────────
# Sends a PromQL expression and returns the numeric value
query_prometheus() {
  local promql="$1"
  curl -s --fail \
    "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${promql}" \
    | jq -r '.data.result[0].value[1] // "N/A"'
}

# ── Helper: color a percentage value ─────────────────────
colorize_percent() {
  local value="$1"
  if [[ "$value" == "N/A" ]]; then
    echo -e "${BLUE}N/A${NC}"
    return
  fi
  local int_val=${value%.*}
  if   (( int_val >= 85 )); then echo -e "${RED}${value}%${NC}"
  elif (( int_val >= 70 )); then echo -e "${YELLOW}${value}%${NC}"
  else                           echo -e "${GREEN}${value}%${NC}"
  fi
}

# ── Check Prometheus is reachable ────────────────────────
if ! curl -s --fail "${PROMETHEUS_URL}/-/healthy" > /dev/null 2>&1; then
  echo -e "${RED}ERROR: Cannot reach Prometheus at ${PROMETHEUS_URL}${NC}"
  echo "Make sure the stack is running: docker compose up -d"
  exit 1
fi

# ════════════════════════════════════════════════════════
# HOST METRICS
# ════════════════════════════════════════════════════════

# CPU usage %
CPU_RAW=$(query_prometheus \
  '(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m]))) * 100')
CPU=$(printf "%.1f" "$CPU_RAW" 2>/dev/null || echo "N/A")

# Memory usage %
MEM_RAW=$(query_prometheus \
  '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100')
MEM=$(printf "%.1f" "$MEM_RAW" 2>/dev/null || echo "N/A")

# Total RAM in GB
MEM_TOTAL_RAW=$(query_prometheus 'node_memory_MemTotal_bytes')
MEM_TOTAL=$(echo "$MEM_TOTAL_RAW" | \
  awk '{printf "%.1f", $1/1024/1024/1024}' 2>/dev/null || echo "N/A")

# Disk usage % on /
DISK_RAW=$(query_prometheus \
  '(1 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"})) * 100')
DISK=$(printf "%.1f" "$DISK_RAW" 2>/dev/null || echo "N/A")

# Disk total size in GB
DISK_TOTAL_RAW=$(query_prometheus \
  'node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}')
DISK_TOTAL=$(echo "$DISK_TOTAL_RAW" | \
  awk '{printf "%.0f", $1/1024/1024/1024}' 2>/dev/null || echo "N/A")

# Network receive KB/s
NET_RX_RAW=$(query_prometheus \
  'rate(node_network_receive_bytes_total{device="eth0"}[2m])')
NET_RX=$(echo "$NET_RX_RAW" | \
  awk '{printf "%.1f", $1/1024}' 2>/dev/null || echo "N/A")

# Network transmit KB/s
NET_TX_RAW=$(query_prometheus \
  'rate(node_network_transmit_bytes_total{device="eth0"}[2m])')
NET_TX=$(echo "$NET_TX_RAW" | \
  awk '{printf "%.1f", $1/1024}' 2>/dev/null || echo "N/A")

# Host uptime in hours
UPTIME_RAW=$(query_prometheus 'node_time_seconds - node_boot_time_seconds')
UPTIME=$(echo "$UPTIME_RAW" | \
  awk '{printf "%.1f", $1/3600}' 2>/dev/null || echo "N/A")

# ════════════════════════════════════════════════════════
# NODE.JS APP METRICS
# ════════════════════════════════════════════════════════

# App status: 1 = UP, 0 = DOWN
APP_UP_RAW=$(query_prometheus 'up{job="nodejs-app"}')
if [[ "$APP_UP_RAW" == "1" ]]; then
  APP_STATUS="${GREEN}UP${NC}"
else
  APP_STATUS="${RED}DOWN${NC}"
fi

# Total HTTP requests
APP_REQUESTS=$(query_prometheus \
  'sum(http_requests_total)')
APP_REQUESTS=$(printf "%.0f" "$APP_REQUESTS" 2>/dev/null || echo "N/A")

# Requests per second (last 2 minutes)
APP_RPS_RAW=$(query_prometheus \
  'sum(rate(http_requests_total[2m]))')
APP_RPS=$(printf "%.2f" "$APP_RPS_RAW" 2>/dev/null || echo "N/A")

# p95 response time in ms
APP_P95_RAW=$(query_prometheus \
  'histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))')
APP_P95=$(echo "$APP_P95_RAW" | \
  awk '{printf "%.0f", $1*1000}' 2>/dev/null || echo "N/A")

# Error rate %
APP_ERR_RAW=$(query_prometheus \
  '(sum(rate(http_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) * 100')
APP_ERR=$(printf "%.1f" "$APP_ERR_RAW" 2>/dev/null || echo "0.0")

# Heap memory used in MB
APP_HEAP_RAW=$(query_prometheus 'app_nodejs_heap_size_used_bytes')
APP_HEAP=$(echo "$APP_HEAP_RAW" | \
  awk '{printf "%.1f", $1/1024/1024}' 2>/dev/null || echo "N/A")

# App uptime in minutes
APP_UPTIME_RAW=$(query_prometheus 'app_uptime_seconds')
APP_UPTIME=$(echo "$APP_UPTIME_RAW" | \
  awk '{printf "%.0f", $1/60}' 2>/dev/null || echo "N/A")

# ════════════════════════════════════════════════════════
# DISPLAY
# ════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         INFRASTRUCTURE METRICS REPORT            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  ${BLUE}Timestamp :${NC} ${TIMESTAMP}"
echo -e "  ${BLUE}Source    :${NC} ${PROMETHEUS_URL}"
echo ""

echo -e "${BOLD}${CYAN}  ── HOST METRICS (Linux / EC2) ──────────────────${NC}"
echo ""
echo -e "${BOLD}  ┌─ CPU ──────────────────────────────────────────┐${NC}"
echo -e "  │  Usage       : $(colorize_percent "$CPU")"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ MEMORY ───────────────────────────────────────┐${NC}"
echo -e "  │  Usage       : $(colorize_percent "$MEM")"
echo -e "  │  Total RAM   : ${MEM_TOTAL} GB"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ DISK (/) ─────────────────────────────────────┐${NC}"
echo -e "  │  Usage       : $(colorize_percent "$DISK")"
echo -e "  │  Total size  : ${DISK_TOTAL} GB"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ NETWORK (eth0) ───────────────────────────────┐${NC}"
echo -e "  │  Receive     : ${NET_RX} KB/s"
echo -e "  │  Transmit    : ${NET_TX} KB/s"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ SYSTEM ───────────────────────────────────────┐${NC}"
echo -e "  │  Uptime      : ${UPTIME} hours"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${BOLD}${CYAN}  ── NODE.JS APP METRICS ─────────────────────────${NC}"
echo ""
echo -e "${BOLD}  ┌─ STATUS ───────────────────────────────────────┐${NC}"
echo -e "  │  App         : $(echo -e $APP_STATUS)"
echo -e "  │  Uptime      : ${APP_UPTIME} minutes"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ TRAFFIC ──────────────────────────────────────┐${NC}"
echo -e "  │  Total reqs  : ${APP_REQUESTS}"
echo -e "  │  Req/sec     : ${APP_RPS}"
echo -e "  │  p95 latency : ${APP_P95} ms"
echo -e "  │  Error rate  : $(colorize_percent "$APP_ERR")"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  ┌─ RUNTIME ──────────────────────────────────────┐${NC}"
echo -e "  │  Heap used   : ${APP_HEAP} MB"
echo -e "${BOLD}  └────────────────────────────────────────────────┘${NC}"
echo ""
