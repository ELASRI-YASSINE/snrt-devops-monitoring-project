'use strict';

const express = require('express');
const client  = require('prom-client');

const app  = express();
const PORT = process.env.PORT || 3001;

// ═══════════════════════════════════════════════════════
// PROMETHEUS SETUP
// ═══════════════════════════════════════════════════════

// Creates a registry — a container that holds all our metrics
const register = new client.Registry();

// collectDefaultMetrics automatically tracks:
//   - Node.js heap memory usage
//   - Event loop lag (how busy the JS thread is)
//   - Active handles and requests
//   - CPU usage of the process
//   - Garbage collection duration
// All of this with zero extra code
client.collectDefaultMetrics({
  register,
  // prefix added to every default metric name
  // e.g. "app_nodejs_heap_size_total_bytes"
  prefix: 'app_',
});

// ── Custom metric 1: HTTP request counter ────────────────
// Counts every HTTP request that comes in
// Labels let us filter by method, route, and status code
// e.g. "how many GET /api/users requests returned 200?"
const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests received',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

// ── Custom metric 2: Request duration histogram ──────────
// Measures how long each request takes in seconds
// A histogram puts values into buckets (e.g. < 0.1s, < 0.5s, < 1s)
// This lets us calculate percentiles in Grafana (p50, p95, p99)
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  // Bucket boundaries in seconds
  // Requests faster than 0.05s go in the first bucket, etc.
  buckets: [0.05, 0.1, 0.2, 0.5, 1, 2, 5],
  registers: [register],
});

// ── Custom metric 3: App uptime gauge ───────────────────
// A gauge is a value that goes up and down (unlike a counter)
// Here it only goes up — tracks how long the app has been running
const appUptime = new client.Gauge({
  name: 'app_uptime_seconds',
  help: 'Uptime of the Node.js application in seconds',
  registers: [register],
});

// Update uptime every 10 seconds
setInterval(() => {
  // process.uptime() returns seconds since Node.js process started
  appUptime.set(process.uptime());
}, 10000);

// ═══════════════════════════════════════════════════════
// MIDDLEWARE
// Runs before every route handler
// Starts a timer when a request arrives,
// then records duration + increments counter when it finishes
// ═══════════════════════════════════════════════════════
app.use((req, res, next) => {
  // Start the timer as soon as the request arrives
  const end = httpRequestDuration.startTimer();

  // "finish" event fires when the response has been sent
  res.on('finish', () => {
    const labels = {
      method:      req.method,
      route:       req.route ? req.route.path : req.path,
      status_code: res.statusCode,
    };
    // Record how long this request took
    end(labels);
    // Increment the total requests counter
    httpRequestsTotal.inc(labels);
  });

  next(); // pass control to the actual route handler
});

// ═══════════════════════════════════════════════════════
// ROUTES
// ═══════════════════════════════════════════════════════

// ── GET / ────────────────────────────────────────────────
// Health check — Prometheus and load balancers use this
// to know if the app is alive
app.get('/', (req, res) => {
  res.json({
    status:  'ok',
    app:     'monitoring-infra demo API',
    version: '1.0.0',
    uptime:  `${Math.floor(process.uptime())}s`,
  });
});

// ── GET /api/users ───────────────────────────────────────
// Simulates a real endpoint that queries a database
// We add artificial delay to generate realistic latency metrics
app.get('/api/users', async (req, res) => {
  // Simulate a DB query taking 50–200ms
  const delay = Math.floor(Math.random() * 150) + 50;
  await new Promise(resolve => setTimeout(resolve, delay));

  const users = [
    { id: 1, name: 'Yassine El Asri', role: 'DevOps Engineer' },
    { id: 2, name: 'Ahmed Benali',    role: 'Backend Developer' },
    { id: 3, name: 'Sara Idrissi',    role: 'Cloud Architect' },
  ];

  res.json({ count: users.length, users });
});

// ── GET /api/status ──────────────────────────────────────
// Returns detailed app status — useful for monitoring dashboards
app.get('/api/status', (req, res) => {
  const mem = process.memoryUsage();
  res.json({
    status:     'ok',
    uptime_sec: Math.floor(process.uptime()),
    memory: {
      heap_used_mb:  Math.round(mem.heapUsed  / 1024 / 1024),
      heap_total_mb: Math.round(mem.heapTotal / 1024 / 1024),
      rss_mb:        Math.round(mem.rss       / 1024 / 1024),
    },
    node_version: process.version,
  });
});

// ── GET /metrics ─────────────────────────────────────────
// THIS IS THE KEY ENDPOINT
// Prometheus scrapes this URL every 15 seconds
// It returns all metrics in the Prometheus text format
app.get('/metrics', async (req, res) => {
  res.setHeader('Content-Type', register.contentType);
  res.send(await register.metrics());
});

// ═══════════════════════════════════════════════════════
// START SERVER
// ═══════════════════════════════════════════════════════
app.listen(PORT, () => {
  console.log(`App running on port ${PORT}`);
  console.log(`Metrics available at http://localhost:${PORT}/metrics`);
});

module.exports = app;
