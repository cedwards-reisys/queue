import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const publishLatency = new Trend('publish_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: 100,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 20,
      maxVUs: 50,
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<500', 'p(99)<1000'],
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
    data: 'x'.repeat(1024),
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  publishLatency.add(res.timings.duration);
  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
}
