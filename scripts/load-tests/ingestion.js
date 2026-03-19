// scripts/load-tests/ingestion.js
// k6 Load Testing — Ingestion Service
// الاستخدام:
//   Smoke:  k6 run --env SCENARIO=smoke   ingestion.js
//   Load:   k6 run --env SCENARIO=load    ingestion.js
//   Stress: k6 run --env SCENARIO=stress  ingestion.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom Metrics ─────────────────────────────────────────────────────
const errorRate       = new Rate('error_rate');
const eventAccepted   = new Counter('events_accepted');
const eventRejected   = new Counter('events_rejected');
const p99Latency      = new Trend('p99_latency', true);

// ── Config ─────────────────────────────────────────────────────────────
const BASE_URL  = __ENV.BASE_URL  || 'http://localhost:9090';
const SCENARIO  = __ENV.SCENARIO  || 'smoke';

// ── Scenarios ──────────────────────────────────────────────────────────
const scenarios = {
  smoke: {
    executor: 'constant-vus',
    vus: 1,
    duration: '30s',
    gracefulStop: '10s',
  },
  load: {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: '1m',  target: 10  },   // ramp up
      { duration: '3m',  target: 50  },   // sustain
      { duration: '1m',  target: 100 },   // peak
      { duration: '2m',  target: 100 },   // sustain peak
      { duration: '1m',  target: 0   },   // ramp down
    ],
    gracefulRampDown: '30s',
  },
  stress: {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: '2m',  target: 100  },
      { duration: '5m',  target: 200  },
      { duration: '2m',  target: 300  },
      { duration: '5m',  target: 300  },
      { duration: '2m',  target: 0    },
    ],
    gracefulRampDown: '30s',
  },
};

// ── Thresholds ─────────────────────────────────────────────────────────
export const options = {
  scenarios: {
    [SCENARIO]: scenarios[SCENARIO],
  },
  thresholds: {
    // 99% من الـ requests تحت 500ms
    'http_req_duration': ['p(99)<500'],
    // error rate تحت 1%
    'error_rate': ['rate<0.01'],
    // 95% من الـ requests تحت 200ms
    'http_req_duration': ['p(95)<200'],
  },
};

// ── Test Data ──────────────────────────────────────────────────────────
const eventTypes = [
  'user.clicked',
  'trade.executed',
  'sensor.reading',
  'order.created',
  'payment.processed',
];

function randomEventType() {
  return eventTypes[Math.floor(Math.random() * eventTypes.length)];
}

function generateEvent() {
  return JSON.stringify({
    event_id:   `load-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    event_type: randomEventType(),
    source:     'k6-load-test',
    payload:    { value: Math.random() * 1000, timestamp: Date.now() },
  });
}

// ── Main Test Function ─────────────────────────────────────────────────
export default function () {
  const payload = generateEvent();

  const params = {
    headers: {
      'Content-Type':     'application/json',
      'X-Event-Type':     randomEventType(),
      'X-Event-Source':   'k6-load-test',
      'X-Schema-Version': '1.0.0',
      'X-Tenant-ID':      'load-test-tenant',
    },
  };

  const res = http.post(`${BASE_URL}/v1/events`, payload, params);

  // ── Checks ────────────────────────────────────────────────────────
  const success = check(res, {
    'status is 200':          (r) => r.status === 200,
    'has event_id':           (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.event_id !== undefined;
      } catch {
        return false;
      }
    },
    'accepted is true':       (r) => {
      try {
        return JSON.parse(r.body).accepted === true;
      } catch {
        return false;
      }
    },
    'response time < 500ms':  (r) => r.timings.duration < 500,
  });

  // ── Custom Metrics ─────────────────────────────────────────────────
  errorRate.add(!success);
  p99Latency.add(res.timings.duration);

  if (res.status === 200) {
    eventAccepted.add(1);
  } else {
    eventRejected.add(1);
  }

  sleep(0.1);
}

// ── Setup: تحقق من الـ service قبل الـ test ────────────────────────────
export function setup() {
  const res = http.get(`${BASE_URL}/healthz`);
  if (res.status !== 200) {
    throw new Error(`Service not ready: ${res.status}`);
  }
  console.log(`k6 targeting: ${BASE_URL} | scenario: ${SCENARIO}`);
  return { baseUrl: BASE_URL };
}

// ── Teardown: summary ──────────────────────────────────────────────────
export function teardown(data) {
  console.log(`Load test complete | target: ${data.baseUrl}`);
}
