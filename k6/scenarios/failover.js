import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const messagesSent = new Counter('messages_sent');
const messagesAcked = new Counter('messages_acked');
const errorRate = new Rate('errors');
const publishLatency = new Trend('publish_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

// Failover test: sustained load for 10 minutes.
// During the test, kill a broker pod externally (manual or via chaos tool).
// Compare messages_sent vs messages consumed (check consumer metrics after test).
// Zero message loss is the target.
export const options = {
  scenarios: {
    failover: {
      executor: 'constant-arrival-rate',
      rate: 50,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  thresholds: {
    'errors': ['rate<0.05'],
    'http_req_duration': ['p(95)<2000', 'p(99)<5000'],
  },
};

export default function () {
  const msgId = `failover-${Date.now()}-${__VU}-${__ITER}`;

  const payload = JSON.stringify({
    id: msgId,
    data: 'x'.repeat(1024),
    persistent: true,
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
  });

  messagesSent.add(1);
  publishLatency.add(res.timings.duration);

  const success = check(res, {
    'status 200': (r) => r.status === 200,
    'not timeout': (r) => r.timings.duration < 10000,
  });

  if (success) {
    messagesAcked.add(1);
  }
  errorRate.add(!success);
}
