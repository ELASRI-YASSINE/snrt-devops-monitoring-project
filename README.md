# Infrastructure Monitoring Stack

A production-grade monitoring solution built with **Prometheus**, **Grafana**, **Alertmanager**, and **Node Exporter** — fully containerized with Docker Compose and delivered via a **GitHub Actions CI/CD pipeline**.

---

## What this project does

This stack monitors a Linux host (AWS EC2) in real time:

- **Collects** metrics every 15 seconds: CPU, RAM, disk, network, uptime
- **Stores** time-series data in Prometheus (15-day retention)
- **Visualizes** everything in Grafana dashboards
- **Fires alerts** when thresholds are exceeded (Alertmanager)
- **Automates** reporting and alert detection with 3 Bash scripts
- **Delivers** changes automatically to EC2 via GitHub Actions

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   AWS EC2 Instance                   │
│                                                      │
│  ┌─────────────┐          ┌────────────────────────┐ │
│  │Node Exporter│          │   Node.js App :3001    │ │
│  │  :9100      │          │  GET /metrics          │ │
│  └──────┬──────┘          └──────────┬─────────────┘ │
│         │  scrapes                   │ scrapes        │
│         └──────────┐   ┌────────────┘               │
│                    ▼   ▼                             │
│              ┌─────────────┐                        │
│              │ Prometheus  │                        │
│              │   :9090     │                        │
│              └──────┬──────┘                        │
│                     │                               │
│            ┌────────┴────────┐                      │
│            ▼                 ▼                      │
│       ┌─────────┐    ┌──────────────┐               │
│       │ Grafana │    │ Alertmanager │               │
│       │  :3000  │    │    :9093     │               │
│       └─────────┘    └──────────────┘               │
└─────────────────────────────────────────────────────┘
```

---

## Stack

| Tool | Role | Port |
|---|---|---|
| Prometheus | Metrics collection & storage | 9090 |
| Node Exporter | Linux host metrics exporter | 9100 |
| Grafana | Dashboards & visualization | 3000 |
| Alertmanager | Alert routing & notifications | 9093 |

---

## Project structure

```
monitoring-infra/
├── docker-compose.yml              # Defines all 4 containers
├── prometheus/
│   ├── prometheus.yml              # Scrape targets and config
│   ├── alerts.yml                  # Alert rules (CPU, RAM, disk)
│   └── alertmanager.yml            # Alert routing config
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── datasource.yml      # Auto-connects Grafana to Prometheus
│       └── dashboards/
│           ├── dashboard.yml       # Tells Grafana where to find JSON dashboards
│           └── host.json           # Pre-built host metrics dashboard
├── scripts/
│   ├── script_metrics.sh           # Query and display live metrics
│   ├── script_alerts.sh            # Check thresholds, log warnings
│   └── script_report.sh            # Generate HTML daily report
└── .github/
    └── workflows/
        └── ci-cd.yml               # GitHub Actions pipeline
```

---

## Quick start

**Prerequisites:** Docker, Docker Compose, Git

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/monitoring-infra.git
cd monitoring-infra

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
| Node Exporter | http://localhost:9100/metrics | — |

---

## Bash scripts

```bash
# Make scripts executable (first time only)
chmod +x scripts/*.sh

# Display live metrics in terminal
./scripts/script_metrics.sh

# Check thresholds and show active alerts
./scripts/script_alerts.sh

# Generate an HTML daily report
./scripts/script_report.sh
# → output saved to /tmp/monitoring_report_YYYY-MM-DD.html
```

---

## CI/CD pipeline (GitHub Actions)

Every push to `main` triggers a 4-stage pipeline:

```
Push to main
    │
    ▼
[1] Validate       → promtool checks prometheus.yml + alerts.yml
                   → shellcheck lints all Bash scripts
    │
    ▼
[2] Security scan  → Trivy scans Docker images for CVEs
    │
    ▼
[3] Build & test   → docker compose up, health checks all services
    │
    ▼
[4] Deploy         → SSH into EC2, git pull, docker compose up -d
```

**Required GitHub secrets:**

| Secret | Value |
|---|---|
| `EC2_HOST` | Your EC2 public IP or DNS |
| `EC2_USER` | `ubuntu` or `ec2-user` |
| `EC2_SSH_KEY` | Content of your `.pem` private key |

---

## Alert thresholds

| Metric | Warning | Critical |
|---|---|---|
| CPU usage | > 80% for 5 min | > 95% for 2 min |
| Memory usage | > 85% for 5 min | > 95% for 2 min |
| Disk usage (/) | > 80% for 5 min | > 90% for 2 min |
| Instance down | — | unreachable > 1 min |

---

## Author

**El Asri Yassine** — Cloud & DevOps Engineer  

