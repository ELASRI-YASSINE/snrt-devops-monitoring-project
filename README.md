# Infrastructure Monitoring Stack

A production-grade monitoring solution built with **Prometheus**, **Grafana**, **Alertmanager**, and **Node Exporter** — fully containerized with Docker Compose, monitoring a real **Node.js REST API**, and delivered via a **GitHub Actions CI/CD pipeline**.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    AWS EC2 Instance                      │
│                                                          │
│  ┌──────────────┐          ┌──────────────────────────┐  │
│  │ Node Exporter│          │   Node.js App :3001      │  │
│  │   :9100      │          │   GET /metrics           │  │
│  └──────┬───────┘          └────────────┬─────────────┘  │
│         │  scrapes every 15s            │ scrapes every 10s
│         └──────────────┐  ┌────────────┘               │
│                        ▼  ▼                             │
│                 ┌──────────────┐                        │
│                 │  Prometheus  │                        │
│                 │    :9090     │                        │
│                 └──────┬───────┘                        │
│                        │                               │
│             ┌──────────┴──────────┐                    │
│             ▼                     ▼                    │
│       ┌───────────┐      ┌──────────────┐              │
│       │  Grafana  │      │ Alertmanager │              │
│       │   :3000   │      │    :9093     │              │
│       └───────────┘      └──────────────┘              │
│                                                          │
│  scripts/                                                │
│  ├── script_metrics.sh  → live metrics in terminal      │
│  ├── script_alerts.sh   → threshold checker + cron      │
│  └── script_report.sh   → HTML daily report             │
└─────────────────────────────────────────────────────────┘
```

---

## CI/CD Pipeline

Every push triggers a 4-stage GitHub Actions pipeline:

```
Push to develop/main
        │
        ▼
[1] Validate
    ├── docker compose config
    ├── promtool check config prometheus.yml
    ├── promtool check rules alerts.yml
    ├── amtool check-config alertmanager.yml
    ├── shellcheck script_metrics.sh
    ├── shellcheck script_alerts.sh
    ├── shellcheck script_report.sh
    └── yamllint grafana provisioning files
        │
        ▼
[2] Security Scan
    ├── Trivy scan node:20-alpine
    ├── Trivy scan prom/prometheus
    ├── Trivy scan grafana/grafana
    └── Trivy scan prom/node-exporter
        │
        ▼
[3] Build & Integration Test
    ├── docker build Node.js app
    ├── docker compose up -d
    ├── health check all 5 services
    └── verify Prometheus scraping targets
        │
        ▼ (main branch only)
[4] Deploy to AWS EC2
    ├── SSH into EC2
    ├── git pull origin main
    ├── docker compose up -d --remove-orphans
    └── health check after deploy
```

---

## Stack

| Tool | Role | Port |
|---|---|---|
| Node.js app | REST API with /metrics endpoint | 3001 |
| Prometheus | Metrics collection and storage | 9090 |
| Node Exporter | Linux host metrics exporter | 9100 |
| Grafana | Dashboards and visualization | 3000 |
| Alertmanager | Alert routing and notifications | 9093 |

---

## Project structure

```
monitoring-infra/
├── App/
│   ├── index.js                    # Node.js REST API with prom-client
│   ├── package.json
│   └── Dockerfile                  # Multi-stage, non-root user, healthcheck
├── docker-compose.yml              # All 5 services on shared network
├── prometheus/
│   ├── prometheus.yml              # Scrape targets: host + nodejs app
│   ├── alerts.yml                  # 12 alert rules for host and app
│   └── alertmanager.yml            # Routing: warning vs critical receivers
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasource.yml      # Auto-connects Grafana to Prometheus
│       └── dashboards/
│           ├── dashboard.yml       # Dashboard loader config
│           └── host.json           # 14-panel dashboard as code
├── scripts/
│   ├── script_metrics.sh           # Live metrics: host + app via Prometheus API
│   ├── script_alerts.sh            # Threshold checker, cron-ready
│   └── script_report.sh            # HTML daily report generator
└── .github/
    └── workflows/
        └── ci-cd.yml               # 4-job GitHub Actions pipeline
```

---

## Quick start

**Prerequisites:** Docker, Docker Compose, Git

```bash
# Clone the repo
git clone https://github.com/ELASRI-YASSINE/snrt-devops-monitoring-project.git
cd snrt-devops-monitoring-project

# Start the full stack
docker compose up -d

# Check all containers are running
docker compose ps
```

**Access the interfaces:**

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin123 |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |
| Node.js app | http://localhost:3001 | — |
| App metrics | http://localhost:3001/metrics | — |
| Node Exporter | http://localhost:9100/metrics | — |

---

## Node.js app endpoints

```bash
GET /              # health check — returns status and uptime
GET /api/users     # returns list of users (simulates DB query with latency)
GET /api/status    # detailed app status: memory, uptime, Node version
GET /metrics       # Prometheus metrics endpoint — scraped every 10s
```

---

## Bash scripts

```bash
# Make scripts executable (first time only)
chmod +x scripts/*.sh

# Display live metrics for host and app
./scripts/script_metrics.sh

# Check thresholds and show active alerts
./scripts/script_alerts.sh

# Generate HTML daily report
./scripts/script_report.sh
cp /tmp/monitoring_report_$(date +%Y-%m-%d).html ~/report.html
firefox ~/report.html
```

**Run script_alerts.sh as a cron job (every 5 minutes):**

```bash
crontab -e
# Add this line:
*/5 * * * * /path/to/scripts/script_alerts.sh >> /var/log/monitoring_alerts.log 2>&1
```

---

## Alert rules

### Host alerts (via Node Exporter)

| Alert | Condition | Severity |
|---|---|---|
| HighCPUUsage | CPU > 80% for 5min | warning |
| CriticalCPUUsage | CPU > 95% for 2min | critical |
| HighMemoryUsage | Memory > 85% for 5min | warning |
| CriticalMemoryUsage | Memory > 95% for 2min | critical |
| HighDiskUsage | Disk > 80% for 5min | warning |
| CriticalDiskUsage | Disk > 90% for 2min | critical |
| InstanceDown | Target unreachable > 1min | critical |

### Node.js app alerts (via prom-client)

| Alert | Condition | Severity |
|---|---|---|
| NodejsAppDown | App unreachable > 1min | critical |
| HighErrorRate | 5xx rate > 10% for 2min | warning |
| CriticalErrorRate | 5xx rate > 30% for 1min | critical |
| SlowResponseTime | p95 latency > 1s for 5min | warning |
| NodejsHighHeapUsage | Heap > 200MB for 5min | warning |

---

## Grafana dashboard panels

The auto-provisioned dashboard has 14 panels in 2 rows:

**Host metrics row:**
CPU gauge · Memory gauge · Disk gauge · Node Exporter status · Host uptime · CPU over time · Memory over time

**Node.js app row:**
App status · App uptime · Error rate · HTTP requests/sec · Response time p50/p95/p99 · Heap memory · Network traffic

---

## GitHub Actions secrets setup

Go to: Repository → Settings → Secrets and variables → Actions

| Secret | Value |
|---|---|
| `EC2_HOST` | Your EC2 public IP or DNS |
| `EC2_USER` | `ubuntu` or `ec2-user` |
| `EC2_SSH_KEY` | Full content of your `.pem` private key |

---

## Author

**El Asri Yassine** — Cloud & DevOps Engineer (2nd year INPT)

