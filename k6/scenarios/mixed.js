import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const smallLatency = new Trend('small_msg_latency_ms');
const largeLatency = new Trend('large_msg_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';
const LARGE_PAYLOAD = 'x'.repeat(5 * 1024 * 1024);
const SMALL_PAYLOAD = 'x'.repeat(1024);

export const options = {
  scenarios: {
    mixed: {
      executor: 'constant-arrival-rate',
      rate: 50,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 20,
      maxVUs: 50,
    },
  },
  thresholds: {
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const isLarge = Math.random() < 0.1;
  const queue = `test-queue-${Math.floor(Math.random() * 10)}`;

  const payload = JSON.stringify({
    id: `mixed-${Date.now()}-${__VU}`,
    queue: queue,
    data: isLarge ? LARGE_PAYLOAD : SMALL_PAYLOAD,
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages/${queue}`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: isLarge ? '30s' : '10s',
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);

  if (isLarge) {
    largeLatency.add(res.timings.duration);
  } else {
    smallLatency.add(res.timings.duration);
  }
}
